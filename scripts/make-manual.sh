#!/usr/bin/env bash
# Makes the PDF of the user manual from its Markdown.
#   scripts/make-manual.sh [out.pdf]     → build/Sirius Manual.pdf
#
# The manual is packaging/agent/manual/: index.md first, then any other .md
# beside it in name order. pandoc turns it into one HTML page with the style
# in scripts/manual/manual.css, and scripts/manual/print-pdf.swift prints
# that page to US Letter with the system's WebKit, so the only tool the
# build needs beyond Xcode's is pandoc (brew install pandoc).

set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE=packaging/agent/manual
OUT="${1:-build/Sirius Manual.pdf}"

if ! command -v pandoc >/dev/null; then
    echo "make-manual: pandoc is not installed; the manual's PDF needs it (brew install pandoc)" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FILES=("$SOURCE/index.md")
while IFS= read -r file; do
    [ "$file" = "$SOURCE/index.md" ] || FILES+=("$file")
done < <(find "$SOURCE" -maxdepth 1 -name '*.md' | sort)

pandoc "${FILES[@]}" \
    --from gfm --to html5 --standalone --embed-resources \
    --metadata pagetitle="Sirius Manual" --metadata lang=en \
    --css scripts/manual/manual.css \
    --output "$WORK/manual.html"

mkdir -p "$(dirname "$OUT")"
swift scripts/manual/print-pdf.swift "$WORK/manual.html" "$OUT"
echo "$OUT"
