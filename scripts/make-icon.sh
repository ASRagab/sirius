#!/usr/bin/env bash
# Renders the app icon from its master, packaging/icon/sirius-icon.svg, and
# the README's from packaging/icon/sirius-readme-icon.svg: the same star and
# colors on a full square, without the app icon's tile.
#   scripts/make-icon.sh
# writes
#   packaging/AppIcon.icns              every standard iconset size, via iconutil
#   packaging/icon/sirius-icon-1024.png the master at 1024 px
#   docs/assets/icon.png                the README header icon, 256 px
#
# Each size is rendered from the vector, not downscaled from 1024, so the
# star's edges stay crisp at 16 and 32 px. The renderer is resvg through a
# pinned npm package, so it needs node and npx on PATH.
set -euo pipefail
cd "$(dirname "$0")/.."

SVG=packaging/icon/sirius-icon.svg
RESVG=(npx --yes @resvg/resvg-js-cli@2.6.2-beta.1)

README_SVG=packaging/icon/sirius-readme-icon.svg

render() {   # render <px> <out.png> [svg]
    "${RESVG[@]}" --fit-width "$1" "${3:-$SVG}" "$2" >/dev/null
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
set=$work/AppIcon.iconset
mkdir "$set"
for pt in 16 32 128 256 512; do
    render "$pt" "$set/icon_${pt}x${pt}.png"
    render $((pt * 2)) "$set/icon_${pt}x${pt}@2x.png"
done
iconutil -c icns -o packaging/AppIcon.icns "$set"

render 1024 packaging/icon/sirius-icon-1024.png
mkdir -p docs/assets
render 256 docs/assets/icon.png "$README_SVG"
echo "wrote packaging/AppIcon.icns, packaging/icon/sirius-icon-1024.png, docs/assets/icon.png"
