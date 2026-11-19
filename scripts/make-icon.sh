#!/usr/bin/env bash
# Renders every icon from the silver star's masters in packaging/icon/:
#   silver-star-app-icon.png   the app icon's tile, corners transparent
#   silver-star.png            the star alone on transparent, for dark backgrounds
#   silver-star-inverted.png   the same star dark, for light backgrounds
#   scripts/make-icon.sh
# writes
#   packaging/AppIcon.icns              every standard iconset size, via iconutil
#   packaging/icon/sirius-icon-1024.png the app icon at 1024 px
#   packaging/images/sirius-star.png    the star in the app (Settings)
#   packaging/images/sirius-star-mark.png  the same, bolder, tinted at small sizes (the pill, toasts)
#   docs/assets/icon.png                the README header icon, 256 px (dark theme)
#   docs/assets/icon-light.png          the same for the light theme
#   landing/assets/favicon-dark.png     64 px, and favicon-light.png
#   landing/assets/apple-touch-icon.png 180 px, the app icon
#
# The app icon's tile fills its master edge to edge, so it is set at 824 px in
# a 1024 px canvas, the margin macOS icons keep. The star images are cut to a
# square around the star first. Only macOS's own tools are used (sips, swift,
# iconutil). The menu-bar star (packaging/images/menubar-star*.png) is made
# separately, from the raster star at 19 pt.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=packaging/icon/silver-star-app-icon.png
STAR=packaging/icon/silver-star.png
INVERTED=packaging/icon/silver-star-inverted.png

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# pad <in> <out> <tile px> <canvas px>: the image centered on a transparent canvas.
cat > "$work/pad.swift" <<'EOF'
import AppKit
let a = CommandLine.arguments
let tile = CGFloat(Double(a[3])!), side = Int(a[4])!
let image = NSImage(contentsOfFile: a[1])!
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
let inset = (CGFloat(side) - tile) / 2
image.draw(in: NSRect(x: inset, y: inset, width: tile, height: tile))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
EOF
pad() { swift "$work/pad.swift" "$@"; }

# The app icon at 1024, then every iconset size from it.
pad "$APP" packaging/icon/sirius-icon-1024.png 824 1024
set=$work/AppIcon.iconset
mkdir "$set"
for pt in 16 32 128 256 512; do
    sips -z "$pt" "$pt" packaging/icon/sirius-icon-1024.png --out "$set/icon_${pt}x${pt}.png" >/dev/null
    sips -z $((pt * 2)) $((pt * 2)) packaging/icon/sirius-icon-1024.png --out "$set/icon_${pt}x${pt}@2x.png" >/dev/null
done
iconutil -c icns -o packaging/AppIcon.icns "$set"
sips -z 180 180 "$APP" --out landing/assets/apple-touch-icon.png >/dev/null

# The star, cut to a square around it (the masters are 1254 px with the star centered near 626, 622).
sips -c 1060 1060 --cropOffset 92 96 "$STAR" --out "$work/star.png" >/dev/null
sips -c 1060 1060 --cropOffset 92 96 "$INVERTED" --out "$work/inverted.png" >/dev/null
sips -z 256 256 "$work/star.png" --out packaging/images/sirius-star.png >/dev/null
# The same star, white, with its alpha raised 2.2 times, for tinting at small sizes (the pill, toasts).
cat > "$work/alpha.swift" <<'SWIFT'
import AppKit
let a = CommandLine.arguments, gain = CGFloat(Double(a[3])!)
let src = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: a[1])))!
let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: src.pixelsWide, pixelsHigh: src.pixelsHigh,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
for y in 0..<src.pixelsHigh { for x in 0..<src.pixelsWide {
    let alpha = min(1, (src.colorAt(x: x, y: y)?.alphaComponent ?? 0) * gain)
    out.setColor(NSColor(deviceRed: 1, green: 1, blue: 1, alpha: alpha), atX: x, y: y)
} }
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
SWIFT
swift "$work/alpha.swift" packaging/images/sirius-star.png packaging/images/sirius-star-mark.png 2.2
mkdir -p docs/assets
sips -z 256 256 "$work/star.png" --out docs/assets/icon.png >/dev/null
sips -z 256 256 "$work/inverted.png" --out docs/assets/icon-light.png >/dev/null
sips -z 64 64 "$work/star.png" --out landing/assets/favicon-dark.png >/dev/null
sips -z 64 64 "$work/inverted.png" --out landing/assets/favicon-light.png >/dev/null

echo "wrote packaging/AppIcon.icns, packaging/icon/sirius-icon-1024.png, packaging/images/sirius-star.png, docs/assets/icon*.png, landing/assets/favicon-*.png, landing/assets/apple-touch-icon.png"
