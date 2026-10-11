#!/usr/bin/env bash
# Convert PDFs into standards/<doc-id>/,
# remove the logo images, and verify the result.
# See AGENTS.md for the full procedure.
#
# Usage: scripts/convert.sh [<pdf>...]
#        With no arguments, converts every PDF in pdfs/inbox/.
#        A PDF from pdfs/inbox/ that converts cleanly is moved to pdfs/.
# Env:   STANDARDS_DIR   output root (default: standards/ at the repo root)
#        LOGO_MAX_BYTES  logo size cutoff in bytes (default: 5000)
#        WORDS_LOST_MAX_PCT  distinct-word loss that triggers a CHECK (default: 10)
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
out_root=${STANDARDS_DIR:-$root/standards}
pdf_root=$root/pdfs
inbox=$pdf_root/inbox
logo_max=${LOGO_MAX_BYTES:-5000}
lost_max=${WORDS_LOST_MAX_PCT:-10}

if [ $# = 0 ]; then
	shopt -s nullglob
	set -- "$inbox"/*.pdf
	shopt -u nullglob
	[ $# -gt 0 ] || { echo "nothing to convert in $inbox"; exit 0; }
fi
# Converting into a locked corpus would start a new standards/ without INDEX.md.
if [ -z "${STANDARDS_DIR:-}" ] && [ ! -f "$out_root/INDEX.md" ]; then
	echo "$out_root/INDEX.md not found; run scripts/vault.sh unlock first" >&2
	exit 2
fi
for cmd in marker_single pdftotext llama-server; do
	command -v $cmd >/dev/null || { echo "$cmd not found" >&2; exit 2; }
done

work_root=$(mktemp -d)
trap 'rm -rf "$work_root"' EXIT

status=0
for pdf in "$@"; do
	id=$(basename "$pdf" .pdf)
	dest=$out_root/$id
	echo "== $id"
	if [ -e "$dest" ]; then
		echo "  SKIP: $dest exists; remove it first to reconvert" >&2
		status=1
		continue
	fi

	work=$work_root/$id
	mkdir -p "$work"
	# balanced mode recognizes tables on the GPU through llama-server;
	# min_recon_score 1.0 sends every table there, since pdftext's own
	# table text drops cells that span several lines.
	if ! marker_single "$pdf" --mode balanced --min_recon_score 1.0 \
		--output_dir "$work" >"$work/marker.log" 2>&1; then
		echo "  FAIL: marker_single; last log lines:" >&2
		tail -5 "$work/marker.log" >&2
		status=1
		continue
	fi

	# Older marker versions nest the output one level deeper; flatten it.
	doc=$work/$id
	if [ ! -f "$doc/$id.md" ] && [ -f "$doc/$id/$id.md" ]; then
		doc=$doc/$id
	fi
	md=$doc/$id.md
	[ -f "$md" ] || { echo "  FAIL: no $id.md in marker output" >&2; status=1; continue; }

	# Remove logos: small AND named _Picture_. Anything that satisfies only
	# one of the two is reported for a look by eye and kept.
	removed=0
	shopt -s nullglob
	for img in "$doc"/*.jpeg "$doc"/*.png; do
		name=$(basename "$img")
		size=$(stat -c %s "$img")
		is_pic=0
		[[ $name == *_Picture_* ]] && is_pic=1
		if [ "$size" -lt "$logo_max" ] && [ $is_pic = 1 ]; then
			esc=${name//./\\.}
			sed -i "/^!\[\]($esc)[[:space:]]*$/d; s/!\[\]($esc)//g" "$md"
			rm "$img"
			removed=$((removed + 1))
		elif [ "$size" -lt "$logo_max" ]; then
			echo "  CHECK: $name is small ($size B) but not a Picture; kept"
		elif [ $is_pic = 1 ] && [ "$size" -lt $((logo_max * 2)) ]; then
			echo "  CHECK: $name is a Picture just above the cutoff ($size B); kept"
		fi
	done

	# Verify: every reference has a file, every file has a reference.
	refs=$(grep -oE '!\[[^]]*\]\([^)]+\)' "$md" | sed -E 's/.*\(([^)]+)\)/\1/' | sort -u || true)
	imgs=("$doc"/*.jpeg "$doc"/*.png)
	files=$( ((${#imgs[@]})) && printf '%s\n' "${imgs[@]##*/}" | sort -u || true)
	missing=$(comm -23 <(printf '%s\n' "$refs" | sed '/^$/d') <(printf '%s\n' "$files" | sed '/^$/d'))
	orphans=$(comm -13 <(printf '%s\n' "$refs" | sed '/^$/d') <(printf '%s\n' "$files" | sed '/^$/d'))
	garbled=$(grep -c $'\xef\xbf\xbd' "$md" || true)
	shopt -u nullglob

	# marker drops multi-line table cells, so keep pdftotext's layout text
	# beside the Markdown as the complete source for tables.
	layout=$doc/$id.layout.txt
	pdftotext -layout "$pdf" "$layout"
	# Bare numbers are mostly page numbers, which never reach the Markdown.
	words() { tr -cs 'A-Za-z0-9' '\n' | awk 'length > 2 && !/^[0-9]+$/' | sort -u; }
	# Page headers and footers repeat on every page and never reach the
	# Markdown; drop lines found on three or more pages before counting.
	body() {
		awk 'BEGIN { RS = "\f" }
			NR == FNR { split("", seen); n = split($0, l, "\n")
				for (i = 1; i <= n; i++) { t = l[i]; gsub(/[ \t]+/, " ", t)
					if (!(t in seen)) { seen[t] = 1; pages[t]++ } }
				next }
			{ n = split($0, l, "\n")
				for (i = 1; i <= n; i++) { t = l[i]; gsub(/[ \t]+/, " ", t)
					if (pages[t] < 3) print l[i] } }' "$1" "$1"
	}
	total=$(body "$layout" | words | wc -l)
	# marker writes subscripts as tags or underscores (Name<sub>i</sub>, Code_1); rejoin them.
	lost=$(comm -23 <(body "$layout" | words) \
		<(sed -E 's#</?su[bp]>##g; s/([A-Za-z])_([0-9A-Za-z])/\1\2/g' "$md" | words) | wc -l)
	lost_pct=$((lost * 100 / (total > 0 ? total : 1)))

	ok=1
	[ -z "$missing" ] || { echo "  FAIL: referenced but missing:" $missing >&2; ok=0; }
	[ -z "$orphans" ] || { echo "  FAIL: image without reference:" $orphans >&2; ok=0; }
	[ "$garbled" = 0 ] || echo "  CHECK: $garbled lines contain U+FFFD (garbled text)"
	[ "$lost_pct" -le "$lost_max" ] ||
		echo "  CHECK: $lost_pct% of the PDF's distinct words are missing from the Markdown; read tables from $id.layout.txt"

	mkdir -p "$out_root"
	mv "$doc" "$dest"
	echo "  lines=$(wc -l <"$dest/$id.md") logos_removed=$removed images=$(printf '%s\n' "$files" | sed '/^$/d' | wc -l) words_lost=$lost_pct%"
	[ $ok = 1 ] || status=1

	# File a cleanly converted inbox PDF with the others.
	if [ $ok = 1 ] && [ "$(cd "$(dirname "$pdf")" && pwd)" = "$inbox" ]; then
		if [ -e "$pdf_root/$id.pdf" ]; then
			echo "  CHECK: $pdf_root/$id.pdf exists; left $pdf in the inbox"
		else
			mv "$pdf" "$pdf_root/"
		fi
	fi
done
exit $status
