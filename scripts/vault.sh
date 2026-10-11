#!/usr/bin/env bash
# Keep each corpus directory in git only as an encrypted archive, <name>.tar.zst.gpg.
# The plaintext directories are gitignored and exist only where they were unlocked.
#
# Usage: scripts/vault.sh unlock [--force] [<name>...]  decrypt archives into their directories
#        scripts/vault.sh lock [--force] [<name>...]    encrypt directories into their archives
#        scripts/vault.sh status [<name>...]            compare each directory with its archive
#        scripts/vault.sh check [<name>...]             exit 1 when a directory has unlocked changes
#        <name> is one of the vaults below; the default is all of them.
#
# One passphrase covers every archive.
# It is read once from the terminal and handed to gpg (AES256, never cached);
# lock checks it against an existing archive before encrypting.
# The last lock/unlock of each vault is recorded in .git/vault.<name>.state,
# so status needs no passphrase.
set -euo pipefail

vaults=(standards manuals)

root=$(cd "$(dirname "$0")/.." && pwd)
git_dir=$(git -C "$root" rev-parse --absolute-git-dir)
# The single-vault version kept its state in .git/vault.state.
if [ -f "$git_dir/vault.state" ] && [ ! -f "$git_dir/vault.standards.state" ]; then
	mv "$git_dir/vault.state" "$git_dir/vault.standards.state"
fi

archive_of() { echo "$root/$1.tar.zst.gpg"; }
state_of() { echo "$git_dir/vault.$1.state"; }

# A canonical tar stream: the same tree always gives the same bytes,
# so its hash tells whether the directory changed.
tree_tar() {
	tar -C "$root" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
		--mode=u=rwX,go=rX --format=gnu -cf - "$1"
}
sha() { sha256sum | cut -d' ' -f1; }
tree_sha() { tree_tar "$1" | sha; }
archive_sha() { sha <"$(archive_of "$1")"; }
# The state file holds "<archive sha> <tree sha>" as of the last lock or unlock.
state_field() {
	local f
	f=$(state_of "$1")
	[ -f "$f" ] && cut -d' ' -f"$2" "$f" || true
}
save_state() { echo "$(archive_sha "$1") $(tree_sha "$1")" >"$(state_of "$1")"; }

# Temporary files live beside the target so the final mv is atomic.
tmp=
trap 'rm -rf "$tmp"' EXIT

pass=
read_pass() {
	{ : <>/dev/tty; } 2>/dev/null || { echo "vault: needs a terminal to read the passphrase" >&2; exit 1; }
	read -rsp "Passphrase: " pass </dev/tty
	echo >/dev/tty
	[ -n "$pass" ] || { echo "vault: empty passphrase" >&2; exit 1; }
}
gpg_pass() {
	gpg --batch --quiet --pinentry-mode loopback --no-symkey-cache --passphrase-fd 3 "$@" 3<<<"$pass"
}

# Reads the passphrase for lock: checked against an existing archive,
# or typed twice when there is none yet.
read_lock_pass() {
	read_pass
	local v
	for v in "${vaults[@]}"; do
		[ -f "$(archive_of "$v")" ] || continue
		gpg_pass --decrypt "$(archive_of "$v")" >/dev/null 2>&1 ||
			{ echo "vault: the passphrase does not open ${v}.tar.zst.gpg" >&2; exit 1; }
		return
	done
	local again
	read -rsp "Repeat: " again </dev/tty
	echo >/dev/tty
	[ "$pass" = "$again" ] || { echo "vault: the passphrases differ" >&2; exit 1; }
}

# Prints one of: locked, clean, modified, outdated, diverged, untracked.
status() {
	local v=$1
	if [ ! -d "$root/$v" ]; then echo locked; return; fi
	if [ ! -f "$(archive_of "$v")" ] || [ ! -f "$(state_of "$v")" ]; then echo untracked; return; fi
	local changed=0 stale=0
	[ "$(tree_sha "$v")" = "$(state_field "$v" 2)" ] || changed=1
	[ "$(archive_sha "$v")" = "$(state_field "$v" 1)" ] || stale=1
	case $changed$stale in
	00) echo clean ;;
	10) echo modified ;;
	01) echo outdated ;;
	11) echo diverged ;;
	esac
}

describe() {
	local v=$1
	case $2 in
	locked) echo "$v: locked: $v/ is absent; run scripts/vault.sh unlock $v" ;;
	clean) echo "$v: clean: $v/ matches the archive" ;;
	modified) echo "$v: modified: $v/ has changes not yet locked; run scripts/vault.sh lock $v" ;;
	outdated) echo "$v: outdated: the archive changed since the last unlock (git pull?); run scripts/vault.sh unlock $v" ;;
	diverged) echo "$v: diverged: both $v/ and the archive changed since the last unlock; merge by hand, then lock --force $v" ;;
	untracked) echo "$v: untracked: $v/ exists but was never locked or unlocked here; run scripts/vault.sh lock $v" ;;
	esac
}

install_hook() {
	if [ -z "$(git -C "$root" config core.hooksPath)" ]; then
		git -C "$root" config core.hooksPath scripts/hooks
		echo "installed the pre-commit hook (core.hooksPath=scripts/hooks)"
	fi
}

unlock_one() {
	local v=$1 archive
	archive=$(archive_of "$v")
	tmp=$(mktemp -d "$root/.vault.XXXXXX")
	gpg_pass --decrypt "$archive" | zstd -dq | tar -C "$tmp" -xf -
	[ -d "$tmp/$v" ] || { echo "vault: ${archive##*/} holds no $v/" >&2; exit 1; }
	rm -rf "${root:?}/$v"
	mv "$tmp/$v" "$root/$v"
	rm -rf "$tmp"
	tmp=
	# Owner-only: the tree hash uses fixed modes, so this does not change status.
	chmod -R go-rwx "$root/$v"
	save_state "$v"
	echo "unlocked $v/ ($(find "$root/$v" -type f | wc -l) files)"
}

lock_one() {
	local v=$1 archive
	archive=$(archive_of "$v")
	tmp=$(mktemp "$root/.vault.XXXXXX")
	tree_tar "$v" | zstd -19 -T0 -q |
		gpg_pass --symmetric --cipher-algo AES256 --compress-algo none \
			--s2k-digest-algo SHA512 --s2k-count 65011712 --yes -o "$tmp"
	mv "$tmp" "$archive"
	tmp=
	save_state "$v"
	echo "locked $v/ into ${archive##*/} ($(du -h "$archive" | cut -f1)); stage and commit it"
}

# Decides per vault, then asks for the passphrase once if any vault has work.
unlock() {
	local v st todo=() rc=0
	for v in "${names[@]}"; do
		if [ ! -f "$(archive_of "$v")" ]; then echo "$v: no archive yet; skipped"; continue; fi
		st=$(status "$v")
		case $st in
		clean) echo "$v: clean: already unlocked" ;;
		locked | outdated) todo+=("$v") ;;
		*)
			if [ "$force" = 1 ]; then todo+=("$v"); else
				describe "$v" "$st" >&2
				echo "$v: unlock would discard $v/; use --force" >&2
				rc=1
			fi
			;;
		esac
	done
	if [ ${#todo[@]} -gt 0 ]; then
		read_pass
		for v in "${todo[@]}"; do unlock_one "$v"; done
		install_hook
	fi
	return $rc
}

lock() {
	local v st todo=() rc=0
	for v in "${names[@]}"; do
		if [ ! -d "$root/$v" ]; then echo "$v: locked: nothing to lock"; continue; fi
		[ -f "$root/$v/INDEX.md" ] || { echo "$v: no $v/INDEX.md; not locked" >&2; rc=1; continue; }
		st=$(status "$v")
		case $st in
		clean) echo "$v: clean: nothing to lock" ;;
		modified | untracked) todo+=("$v") ;;
		*)
			if [ "$force" = 1 ]; then todo+=("$v"); else
				describe "$v" "$st" >&2
				echo "$v: lock would overwrite the newer archive; use --force" >&2
				rc=1
			fi
			;;
		esac
	done
	if [ ${#todo[@]} -gt 0 ]; then
		read_lock_pass
		for v in "${todo[@]}"; do lock_one "$v"; done
		install_hook
	fi
	return $rc
}

cmd=${1:-}
[ $# -gt 0 ] && shift
force=0
names=()
for arg in "$@"; do
	case $arg in
	--force) force=1 ;;
	*)
		[[ " ${vaults[*]} " == *" $arg "* ]] || { echo "vault: unknown vault '$arg' (one of: ${vaults[*]})" >&2; exit 2; }
		names+=("$arg")
		;;
	esac
done
[ ${#names[@]} -gt 0 ] || names=("${vaults[@]}")

case $cmd in
unlock) unlock ;;
lock) lock ;;
status) for v in "${names[@]}"; do describe "$v" "$(status "$v")"; done ;;
check)
	rc=0
	for v in "${names[@]}"; do
		st=$(status "$v")
		case $st in
		locked | clean | outdated) ;;
		*) describe "$v" "$st" >&2; rc=1 ;;
		esac
	done
	exit $rc
	;;
*) sed -n '5,9s/^# //p' "$0" >&2; exit 2 ;;
esac
