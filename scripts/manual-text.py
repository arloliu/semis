#!/usr/bin/env python3
"""Convert a vendor manual PDF into page text an agent can read and cite.

Usage: scripts/manual-text.py <manual.pdf> [<out-dir>]

The output directory defaults to manuals/<model>/<manual>/ for pdfs/manuals/<model>/<manual>.pdf
and receives:
  pages/pNNNN.txt     one file per PDF page, from pdftotext -layout; the page number is the citation unit
  toc.tsv             the PDF bookmarks, one per line: level (0 = top), title, start page (empty if none)
  rotated_pages.txt   the pages with a nonzero /Rotate, space-separated on one line;
                      their layout text is the least reliable and is checked against the PDF page

All three outputs are built in a staging directory and replace the previous ones only when every one succeeded,
so a failed run leaves the previous output as it was.
Needs poppler-utils (pdfinfo, pdftotext, pdftohtml); Python standard library only.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROT_RE = re.compile(r"^Page\s+(\d+)\s+rot:\s+(\d+)\s*$")
PAGES_RE = re.compile(r"^Pages:\s+(\d+)\s*$")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def run(*args):
    """Run a poppler command and return its stdout as text."""
    return subprocess.run(args, check=True, capture_output=True, text=True, errors="replace").stdout


def page_count(pdf):
    for line in run("pdfinfo", pdf).splitlines():
        m = PAGES_RE.match(line)
        if m:
            return int(m.group(1))
    raise ValueError(f"pdfinfo reports no page count for {pdf}")


def rotated_pages(pdf, pages):
    rotated = []
    for line in run("pdfinfo", "-f", "1", "-l", str(pages), pdf).splitlines():
        m = ROT_RE.match(line)
        if m and int(m.group(2)) % 360 != 0:
            rotated.append(int(m.group(1)))
    return rotated


def write_pages(pdf, pages, pages_dir):
    """Write one layout-text file per page into pages_dir.

    pdftotext ends every page with a form feed, so one run over the whole document is split on it;
    each file keeps its form feed, as a single-page pdftotext run writes it.
    Any other number of form feeds would shift every later page, so it fails the run.
    """
    text = run("pdftotext", "-layout", "-enc", "UTF-8", pdf, "-")
    chunks = text.split("\f")
    if len(chunks) != pages + 1 or chunks[-1] != "":
        raise ValueError(f"pdftotext returned {text.count(chr(12))} form feeds for {pages} pages")
    os.makedirs(pages_dir)
    width = max(4, len(str(pages)))
    for i in range(pages):
        with open(os.path.join(pages_dir, f"p{i + 1:0{width}d}.txt"), "w", encoding="utf-8") as f:
            f.write(chunks[i] + "\f")


def toc_rows(pdf):
    """Return (level, title, page) for every bookmark, in document order."""
    xml = run("pdftohtml", "-xml", "-i", "-q", "-stdout", "-f", "1", "-l", "1", pdf)
    root = ET.fromstring(xml)
    top = root.find("outline")
    rows = []

    def walk(outline, level):
        for child in outline:
            if child.tag == "item":
                title = " ".join("".join(child.itertext()).split())
                rows.append((level, title, child.get("page", "")))
            elif child.tag == "outline":
                walk(child, level + 1)

    if top is not None:
        walk(top, 0)
    return rows


def main(argv):
    if len(argv) not in (2, 3):
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    pdf = argv[1]
    if len(argv) == 3:
        out = argv[2]
    else:
        pdf_path = os.path.abspath(pdf)
        model_dir = os.path.dirname(pdf_path)
        if os.path.dirname(model_dir) != os.path.join(ROOT, "pdfs", "manuals"):
            raise SystemExit("manual-text: give <out-dir> for a PDF outside pdfs/manuals/<model>/")
        stem = os.path.splitext(os.path.basename(pdf_path))[0]
        out = os.path.join(ROOT, "manuals", os.path.basename(model_dir), stem)
    for tool in ("pdfinfo", "pdftotext", "pdftohtml"):
        if shutil.which(tool) is None:
            raise SystemExit(f"manual-text: {tool} not found; install poppler-utils")
    os.makedirs(out, exist_ok=True)

    stage = tempfile.mkdtemp(prefix=".manual-text-", dir=out)
    try:
        pages = page_count(pdf)
        write_pages(pdf, pages, os.path.join(stage, "pages"))
        rows = toc_rows(pdf)
        with open(os.path.join(stage, "toc.tsv"), "w", encoding="utf-8") as f:
            for level, title, page in rows:
                f.write(f"{level}\t{title}\t{page}\n")
        rotated = rotated_pages(pdf, pages)
        with open(os.path.join(stage, "rotated_pages.txt"), "w", encoding="utf-8") as f:
            f.write(" ".join(str(p) for p in rotated) + "\n")

        # Move the old pages aside rather than deleting them, so a failed swap can put them back.
        pages_dir, old = os.path.join(out, "pages"), os.path.join(stage, "old-pages")
        if os.path.exists(pages_dir):
            os.replace(pages_dir, old)
        try:
            os.replace(os.path.join(stage, "pages"), pages_dir)
        except OSError:
            if os.path.exists(old):
                os.replace(old, pages_dir)
            raise
        for name in ("toc.tsv", "rotated_pages.txt"):
            os.replace(os.path.join(stage, name), os.path.join(out, name))
    except subprocess.CalledProcessError as e:
        raise SystemExit(f"manual-text: {e.cmd[0]} failed (exit {e.returncode}): {e.stderr.strip()}")
    except (ET.ParseError, ValueError, OSError) as e:
        raise SystemExit(f"manual-text: {e}")
    finally:
        shutil.rmtree(stage, ignore_errors=True)

    print(f"manual-text: {pages} pages, {len(rows)} bookmarks, {len(rotated)} rotated pages -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
