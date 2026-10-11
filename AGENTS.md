# Document corpus

Two corpora, each converted from PDFs into text an agent can read:

```
standards/                  standards, Markdown per document
  INDEX.md                  the reader's map: which document and section answers which question
  <doc-id>/                 <doc-id>.md, its figures, <doc-id>.layout.txt
manuals/                    vendor equipment manuals, text per PDF page
  INDEX.md                  the reader's map: each manual's source, version and chapters
  <model>/<manual>/         pages/pNNNN.txt, toc.tsv, rotated_pages.txt
pdfs/                       source PDFs, not tracked by git
  <doc-id>.pdf              standards (read-only, mode 440)
  inbox/                    standards waiting for conversion
  manuals/<model>/<manual>.pdf
```

`<doc-id>` and `<manual>` are the PDF's base name; `<model>` names the equipment model in lower case.
Read a corpus's `INDEX.md` first for any lookup; the steps below are only for adding a document.

Git tracks `standards/` and `manuals/` only as the encrypted `standards.tar.zst.gpg` and `manuals.tar.zst.gpg`;
`scripts/vault.sh unlock` and `lock` convert between the two (see "Encrypted corpus" below).
Both ask for a passphrase on the terminal, which only the user has:
if a corpus directory is absent, ask the user to run `scripts/vault.sh unlock`; never run it yourself.
Nothing read from `manuals/` enters a tracked file or a commit message:
no vendor, model, document number or quoted text; name a manual by its role ("the equipment manual").

## Adding a standard

1. **Convert**: put the PDFs in `pdfs/inbox/` and run `scripts/convert.sh` (or `scripts/convert.sh <pdf>...`).
   Run it outside any agent sandbox: `marker_single` writes a lock file under `~/.cache/datalab`.
   It runs marker in balanced mode, which recognizes tables on the GPU through `llama-server`
   (llama.cpp Vulkan build in `~/.local/opt/llama.cpp/`, linked from `~/.local/bin`); expect about 12 s per page.
   It converts each PDF, removes the logo images, writes `<doc-id>.layout.txt` (`pdftotext -layout`),
   moves the result into `standards/<doc-id>/`, and moves each cleanly converted PDF from `pdfs/inbox/` to `pdfs/`;
   it refuses a `<doc-id>` that already exists, so delete that directory to reconvert.
   Reconvert into a scratch directory first (`STANDARDS_DIR=<dir>`);
   replace a document only when the new conversion loses fewer words.
   Done when every document printed a `lines=… words_lost=…` line and the script exited 0.
2. **Resolve every `CHECK` line** the script printed, by opening the named image or text.
   - Logo removal deletes an image only when it is both under the size cutoff (5000 B) and named `_Picture_`.
     The publisher's logo appears on every page as a ~3.7–4.1 KB `_Picture_` JPEG;
     real diagrams are named `_Diagram_` or `_Figure_`.
     A logo the script kept gets removed by hand (file and its `![](…)` line); a real picture stays.
   - The size gap is not universal: one document's diagrams start at 5.9 KB, so never lower the cutoff without checking.
   - A `words_lost` CHECK means text is missing from the `.md`, most often table cells.
     Page footers and subscripts split from their word (`Name<sub>i</sub>`) count as lost but are not;
     a short document reaches 8–10% on those alone.
     The verdict is the "words lost" figure in the INDEX entry, plus a note on any key table that is empty in the `.md`
     (compare the table's caption in `.md` and `.layout.txt`).
   - `U+FFFD` lines mean the PDF's text layer is broken there; read that passage in the `.layout.txt`.

   Done when every `CHECK` line has a verdict and no logo remains (`ls -l --block-size=1 standards/<doc-id>/*Picture*`).
3. **Index it** in `standards/INDEX.md`:
   - a `### <standard>-<revision> — <title>` entry:
     the path, line count, words lost, a one-line purpose and a section table;
     a `.1` standard goes right after its base standard's entry,
     and its table names each service's message ID as the `.layout.txt` gives it;
   - rows in "Quick lookup by topic";
   - an update to "How the documents relate" when the standard joins a new layer or depends on others.

   Build the section table from the headings (`grep -nE '^#{1,4} ' <doc-id>.md`);
   marker's heading levels are unreliable, so take the numbering from the text, not the `#` count.
   Done when every top-level numbered section and every state model or service list in the document has a row.
4. **Lock it**: ask the user to run `scripts/vault.sh lock`, then commit `standards.tar.zst.gpg`.
   `scripts/vault.sh status` (no passphrase) must print `clean` before the commit.

## Adding a manual

1. **Convert**: put the PDF at `pdfs/manuals/<model>/<manual>.pdf` and run `python3 scripts/manual-text.py <pdf>`.
   It needs Python 3 and poppler-utils (`pdfinfo`, `pdftotext`, `pdftohtml`) and takes about a second per thousand pages.
   It writes `manuals/<model>/<manual>/`; a rerun replaces the previous output only when every step succeeded.
   - `pages/pNNNN.txt`: the `pdftotext -layout` text of one page.
     The PDF page number, not the printed page label, is the citation unit: cite "manual p. N".
   - `toc.tsv`: the PDF bookmarks, tab-separated: level (0 is top), title, start page (empty when the bookmark has no target).
   - `rotated_pages.txt`: the pages with a nonzero rotation, mostly landscape tables;
     their layout text is the least reliable, so check them against the PDF page.
2. **Index it** in `manuals/INDEX.md`: a `## <model> — <title>` entry with the path; page, bookmark and rotated-page counts;
   the source (document number, revision, date, software version, from the title page); a one-line purpose;
   and a chapter table from the level-0 rows of `toc.tsv` with PDF page ranges and the related standards in `standards/`.
3. **Lock it**: ask the user to run `scripts/vault.sh lock`, then commit `manuals.tar.zst.gpg`.

## Encrypted corpus

Each vault, `standards` and `manuals`, is a directory tracked as `<name>.tar.zst.gpg`:
a tar of the directory compressed with zstd and encrypted by gpg with a passphrase (AES256).
One passphrase covers every archive;
`vault.sh` reads it once from the terminal, and gpg never caches it.
`lock` checks it against an existing archive before encrypting, so a typo cannot create a second passphrase.

```sh
scripts/vault.sh unlock   # decrypt into the directories (after a clone or a pull that changed an archive)
scripts/vault.sh status   # compare each directory with its archive; asks for no passphrase
scripts/vault.sh lock     # encrypt the changed directories into their archives
git add standards.tar.zst.gpg manuals.tar.zst.gpg && git commit
```

Every command acts on all vaults, or only on those named after it (`scripts/vault.sh lock manuals`).
`unlock` makes the directories owner-only (`chmod -R go-rwx`).
`status` reports one of, per vault:

| Status | Meaning | Next step |
|---|---|---|
| `locked` | the directory is absent | `unlock` |
| `clean` | the directory matches the archive | none |
| `modified` | the directory has edits the archive lacks | `lock`, then commit the archive |
| `outdated` | the archive changed since the last unlock, e.g. after `git pull` | `unlock` |
| `diverged` | both changed | merge by hand, then `lock --force` |
| `untracked` | the directory was never locked or unlocked in this clone | `lock` |

`unlock` refuses to overwrite unlocked edits, and `lock` refuses to overwrite a newer archive;
`--force` overrides either.
The first `lock` or `unlock` also sets `core.hooksPath=scripts/hooks`,
whose pre-commit hook refuses a commit while any vault is `modified`, `diverged` or `untracked`
(bypass with `git commit --no-verify`).

Every `lock` rewrites a whole archive (standards about 5 MB), so lock once per batch of edits, not per edit.
A lost passphrase cannot be recovered; store it in a password manager.

## Conventions

- An object standard defines abstract services only;
  its protocol mapping is the `.1` subsidiary standard.
  Keep INDEX's "Not in this corpus" line current, so a reader knows which answers are missing.
- Keep the PDFs unmodified; every fix happens in the Markdown copy.
