#!/usr/bin/env python3
"""Checks that every local link and image in the docs resolves to a real file.

`mkdocs build --strict` already fails on a broken internal link between Markdown pages, which is
most of this. Two things it does not cover are what this exists for:

- an image reference written as raw HTML, which MkDocs never parses as a link;
- a link to a non-Markdown file shipped alongside the docs, such as the example property list.

It also refuses absolute paths, which resolve on a deployed site and break in every local
preview and under any path prefix.

Run from the repository root. Exits non-zero and names each failure.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

DOCS = Path(__file__).resolve().parent.parent / "docs"

MARKDOWN_LINK = re.compile(r"!?\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
HTML_SRC = re.compile(r"<(?:img|source)\b[^>]*?\bsrc\s*=\s*[\"']([^\"']+)[\"']", re.IGNORECASE)
HTML_HREF = re.compile(r"<a\b[^>]*?\bhref\s*=\s*[\"']([^\"']+)[\"']", re.IGNORECASE)

EXTERNAL_SCHEMES = {"http", "https", "mailto", "tel", "ftp"}


def targets(text: str):
    for pattern in (MARKDOWN_LINK, HTML_SRC, HTML_HREF):
        for match in pattern.finditer(text):
            yield match.group(1)


def resolve(page: Path, target: str) -> Path | None:
    """The file a target names, or None when the target is not a local file reference."""
    parts = urlsplit(target)
    if parts.scheme in EXTERNAL_SCHEMES or target.startswith("//"):
        return None
    path = unquote(parts.path)
    if not path:  # a bare fragment, such as #undo, which mkdocs --strict validates
        return None
    return (page.parent / path).resolve()


def main() -> int:
    failures: list[str] = []

    for page in sorted(DOCS.rglob("*.md")):
        text = page.read_text(encoding="utf-8")
        for target in targets(text):
            if target.startswith("/"):
                failures.append(
                    f"{page.relative_to(DOCS.parent)}: absolute path '{target}'. "
                    "Write it relative to the page instead."
                )
                continue

            resolved = resolve(page, target)
            if resolved is None:
                continue

            # A link between pages is written as another page's file name, which is how MkDocs
            # wants it and how --strict can check the anchor too.
            if resolved.exists():
                continue

            failures.append(f"{page.relative_to(DOCS.parent)}: '{target}' does not exist")

    if failures:
        print("Broken local references in the docs:")
        for failure in failures:
            print(f"    {failure}")
        return 1

    pages = len(list(DOCS.rglob("*.md")))
    print(f"Every local link and image across {pages} docs pages resolves.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
