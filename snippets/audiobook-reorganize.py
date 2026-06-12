#!/usr/bin/env python3
"""
audiobook-reorganize.py — Strip author prefix + sort into series subfolders.

Designed for Audiobookshelf libraries where book folders follow the pattern:
  "Author Name - Series Name NN - Book Title"

Reorganizes into the ABS-recommended structure:
  Author/
  └── Series Name/
      └── NN - Book Title/

Standalone books (no series number detected) stay flat under the author dir.

Usage:
  python3 audiobook-reorganize.py <author_dir> [<author_dir2> ...] [--execute]

  Default: dry-run (no changes made).
  --execute: apply changes.

Dependencies: Python 3.6+, no third-party packages.
"""
import sys, re
from pathlib import Path

# Map author folder name → list of prefix variants to strip from book folders.
# A prefix variant is the leading "Author Name" segment before the first " - ".
# Multiple variants handle cases where the folder name and the prefix in book
# names differ (e.g. typos, co-author combos). An empty list means no prefix
# stripping (book folders already lack an author prefix).
#
# Example:
#   "Jane Doe": ["Jane Doe"],
#   "Jane Doe (alt)": ["Jane Doe", "J. Doe"],
#   "Podcast Series": [],   # no author prefix in folder names
AUTHOR_PREFIXES = {
    # "Author Name": ["Prefix Variant 1", "Prefix Variant 2"],
}

# Matches "Series - Folge/Band/Teil/Episode/Staffel/Buch NN - Title"
RE_KEYWORD = re.compile(
    r'^(.+?)\s*-\s*(Folge|Band|Teil|Episode|Staffel|Buch)\s+(\d{1,4}(?:\.\d+)?)\s+-\s+(.+)$',
    re.IGNORECASE
)
# Matches "Series NN - Title"
RE_PLAIN = re.compile(
    r'^(.+?)\s+(\d{1,4}(?:\.\d+)?)\s+-\s+(.+)$'
)


def detect_series(name):
    """Return (series, num, title) or None if no series pattern found."""
    m = RE_KEYWORD.match(name)
    if m:
        return m.group(1).strip(), m.group(3), m.group(4).strip()
    m = RE_PLAIN.match(name)
    if m and len(m.group(1).strip()) >= 3:
        return m.group(1).strip(), m.group(2), m.group(3).strip()
    return None


def strip_prefix(name, prefixes):
    """Strip a known author prefix from the start of a folder name."""
    parts = name.split(' - ', 1)
    if len(parts) < 2:
        return None
    lead = parts[0]
    for p in prefixes:
        if lead == p or lead.startswith(p + ',') or lead.startswith(p + ' &'):
            return parts[1]
    return None


def compute_moves(author_dir, prefixes):
    moves, warnings = [], []
    seen_targets = {}

    for child in sorted(author_dir.iterdir()):
        if not child.is_dir():
            continue
        name = child.name
        stripped = strip_prefix(name, prefixes) if prefixes else None
        clean = stripped if stripped is not None else name
        series_info = detect_series(clean)

        if series_info:
            series, num, title = series_info
            new_rel = Path(series) / f"{num} - {title}"
        else:
            new_rel = Path(clean)

        new_path = author_dir / new_rel

        if new_path == child:
            continue

        rel_str = str(new_rel)
        if rel_str in seen_targets:
            warnings.append(
                f"  !! CONFLICT: '{name}'\n"
                f"     same target as '{seen_targets[rel_str]}'\n"
                f"     → '{rel_str}' — SKIPPED"
            )
            continue
        if new_path.exists():
            warnings.append(f"  !! EXISTS: target '{rel_str}' already on disk — SKIPPED")
            continue

        seen_targets[rel_str] = name
        moves.append((child, new_path, clean, series_info))

    return moves, warnings


def main():
    args = sys.argv[1:]
    execute = '--execute' in args
    dirs = [a for a in args if not a.startswith('--')]

    if not dirs:
        print(__doc__)
        sys.exit(1)

    for dir_arg in dirs:
        author_dir = Path(dir_arg)
        if not author_dir.is_dir():
            print(f"Error: not a directory: {dir_arg}")
            continue

        author_name = author_dir.name
        prefixes = AUTHOR_PREFIXES.get(author_name, [author_name])

        print(f"\n{'='*60}")
        print(f"Author : {author_name}")
        print(f"Prefix : {prefixes or '(none — no stripping)'}")
        print(f"Mode   : {'*** EXECUTE ***' if execute else 'dry-run'}")
        print('='*60)

        moves, warnings = compute_moves(author_dir, prefixes)

        for old, new, clean, series_info in moves:
            if series_info:
                series, num, title = series_info
                print(f"  '{old.name}'")
                print(f"    → [{series}] / {num} - {title}")
            else:
                print(f"  '{old.name}'")
                print(f"    → {clean}  (standalone)")
            print()

        for w in warnings:
            print(w)

        print(f"  --- {len(moves)} moves, {len(warnings)} skipped ---")

        if execute:
            if not moves:
                print("  Nothing to do.")
                continue
            print("\n  Executing...")
            for old, new, _, _ in moves:
                new.parent.mkdir(parents=True, exist_ok=True)
                old.rename(new)
            print("  Done.")


if __name__ == '__main__':
    main()
