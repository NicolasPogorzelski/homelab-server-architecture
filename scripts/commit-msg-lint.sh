#!/usr/bin/env bash
set -euo pipefail

MSG_FILE="$1"
SUBJECT=$(head -1 "$MSG_FILE")

# skip auto-generated messages
if echo "$SUBJECT" | grep -qP '^(Merge|Revert|fixup!|squash!)'; then
    exit 0
fi

PATTERN='^(feat|fix|docs|refactor|chore|test|ci)\([a-z0-9-]+\): .+'

if ! echo "$SUBJECT" | grep -qP "$PATTERN"; then
    echo "ERROR: Commit message format invalid." >&2
    echo "Expected: type(scope): description" >&2
    echo "Types:    feat fix docs refactor chore test ci" >&2
    echo "Got:      $SUBJECT" >&2
    exit 1
fi
