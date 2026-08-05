#!/usr/bin/env bash
# Build Resources/AppIcon.icns from miniclockify.svg.
# The logo has a non-square viewBox, so we wrap it centered in a square
# canvas (with padding) before rendering the macOS iconset sizes.
set -euo pipefail

SRC="miniclockify.svg"
OUT="Resources/AppIcon.icns"
SQUARE=".build/AppIcon.square.svg"
ICONSET=".build/AppIcon.iconset"

# Native logo dimensions (from the SVG viewBox).
LOGO_W=730.31531
LOGO_H=795.62219

# Apple macOS icon grid (Big Sur+): 1024 canvas, an 824x824 rounded "body"
# centered with a 100px margin, corner radius 185.4 (the HIG squircle value).
CANVAS=1024
BODY=824
MARGIN=100
RADIUS=185.4
BG="#FFFFFF"       # squircle fill; navy glyph needs a light backdrop
FILL=0.62          # fraction of the body the glyph occupies (inset padding)

# scale so the glyph's tallest dimension = BODY*FILL, then center on the canvas.
read -r SCALE TX TY < <(awk -v w="$LOGO_W" -v h="$LOGO_H" -v c="$CANVAS" -v b="$BODY" -v f="$FILL" \
  'BEGIN { s = (b*f)/h; printf "%.6f %.6f %.6f\n", s, (c - w*s)/2, (c - h*s)/2 }')

mkdir -p "$ICONSET"

# Square wrapper: Apple squircle background + original paths re-centered on top.
INNER=$(sed -n '/<style/,/<\/svg>/p' "$SRC" | sed '$d')
cat > "$SQUARE" <<SVG
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="$CANVAS" height="$CANVAS" viewBox="0 0 $CANVAS $CANVAS">
<rect x="$MARGIN" y="$MARGIN" width="$BODY" height="$BODY" rx="$RADIUS" ry="$RADIUS" fill="$BG"/>
<g transform="translate($TX,$TY) scale($SCALE)">
$INNER
</g>
</svg>
SVG

# macOS iconset: base size + @2x for each.
for spec in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$(( spec * scale ))
    suffix=""; [ "$scale" = 2 ] && suffix="@2x"
    rsvg-convert -w "$px" -h "$px" "$SQUARE" -o "$ICONSET/icon_${spec}x${spec}${suffix}.png"
  done
done

iconutil -c icns "$ICONSET" -o "$OUT"
echo "Built $OUT"
