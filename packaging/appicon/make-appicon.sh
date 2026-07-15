#!/bin/bash
# Assemble app/DNSwitch/AppIcon.icon from the Icon Composer layers.
#   packaging/appicon/make-appicon.sh
# This is the macOS 26 "Liquid Glass" icon: a layered .icon bundle that actool
# compiles (and also bakes a backwards-compatible .icns for older macOS). The hat
# and stars are white masks tinted by per-layer fills; actool applies the glass
# material automatically. The menu-bar glyph is a SEPARATE thing (an SF-style
# template imageset) and is unrelated to this.
#
# Palette from the designer's README (ICONCOMPOSER-README.md). The background uses
# automatic-gradient from the mid purple: Icon Composer's explicit 3-stop
# linear-gradient JSON schema resisted reverse-engineering, and the auto gradient
# from #4C1D95 reproduces the light-top/dark-bottom look. To set the exact 3 stops
# (#8B5CF6 → #4C1D95 → #1E1B4B), open this .icon in Icon Composer and set the
# canvas Fill → Gradient by hand.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ICON="$DIR/app/DNSwitch/AppIcon.icon"
rm -rf "$ICON"; mkdir -p "$ICON/Assets"
cp "$DIR/packaging/appicon/layers/1_stars.png" "$DIR/packaging/appicon/layers/2_hat.png" "$ICON/Assets/"
cat > "$ICON/icon.json" <<'JSON'
{
  "fill" : { "automatic-gradient" : "srgb:0.298,0.114,0.584,1" },
  "groups" : [
    { "layers" : [
        { "image-name" : "1_stars.png", "name" : "stars", "fill" : { "solid" : "srgb:0.992,0.902,0.541,1" } },
        { "image-name" : "2_hat.png",   "name" : "hat",   "fill" : { "solid" : "srgb:1,1,1,1" } }
    ] }
  ],
  "supported-platforms" : { "circles" : ["watchOS"], "squares" : "shared" }
}
JSON
echo "wrote $ICON"
