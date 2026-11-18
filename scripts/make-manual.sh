#!/usr/bin/env bash
# Makes the PDF of the user manual from its Markdown, with Paper.
#   scripts/make-manual.sh [out.pdf]     → build/Sirius Manual.pdf
#
# The manual is docs/manual/: index.md first, then any other .md
# beside it in name order, exported as one document by `paper export`
# (Paper's command-line tool; no window opens).
#
#   SIRIUS_MANUAL_STYLE   Paper's page style (default: Paper's own default)

set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE=docs/manual
OUT="${1:-build/Sirius Manual.pdf}"

if ! command -v paper >/dev/null; then
    echo "make-manual: the paper command is not installed; the manual's PDF is made with Paper" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# One file for Paper: index.md, then the other sections.
cat "$SOURCE/index.md" > "$WORK/Sirius Manual.md"
while IFS= read -r file; do
    [ "$file" = "$SOURCE/index.md" ] && continue
    printf '\n' >> "$WORK/Sirius Manual.md"
    cat "$file" >> "$WORK/Sirius Manual.md"
done < <(find "$SOURCE" -maxdepth 1 -name '*.md' | sort)

mkdir -p "$(dirname "$OUT")"
STYLE=()
[ -n "${SIRIUS_MANUAL_STYLE:-}" ] && STYLE=(--style "$SIRIUS_MANUAL_STYLE")
paper export "$WORK/Sirius Manual.md" -o "$OUT" --paper letter ${STYLE[@]+"${STYLE[@]}"} >/dev/null
[ -s "$OUT" ] || { echo "make-manual: paper export wrote nothing to $OUT" >&2; exit 1; }
echo "$OUT"
