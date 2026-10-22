#!/bin/zsh --no-rcs
# Renders App/AppIcon.svg into the app's icon set and the website's icons. Needs rsvg-convert (brew install librsvg).
set -eu
cd "$(dirname "$0")/.."
set_=App/Remora/Assets.xcassets/AppIcon.appiconset
for px in 16 32 64 128 256 512 1024; do rsvg-convert -w $px App/AppIcon.svg -o $set_/mac-$px.png; done
cp $set_/mac-256.png site/img/icon.png
cp $set_/mac-64.png site/img/favicon.png
# iOS masks a home-screen icon itself, so the touch icon is the tile full-bleed, without its own corners and shadow
sed 's|<rect id="tile"[^>]*>|<rect width="1024" height="1024" fill="url(#g)"/>|' App/AppIcon.svg | rsvg-convert -w 180 -o site/img/apple-touch-icon.png
