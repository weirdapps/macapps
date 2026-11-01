#!/bin/zsh
# Builds every app, zips each bundle for a GitHub release, and refreshes the website's icons and screenshots.
# Usage: scripts/release.sh   (then: gh release create vX.Y.Z build/release/*.zip)
set -euo pipefail
cd "${0:A:h}/.."

scripts/build.sh
APPS=(Apps/*/Info.plist(:h:t))
rm -rf build/release && mkdir -p build/release docs/icons docs/screenshots

for app in $APPS; do
  ditto -c -k --keepParent "build/$app.app" "build/release/$app.zip"
  sips -z 256 256 "build/icons/$app.png" --out "docs/icons/$app.png" >/dev/null
  # --snapshot renders fixed demo data, never the data of the Mac it runs on.
  "build/$app.app/Contents/MacOS/$app" --snapshot "docs/screenshots/$app.png"
done

rm -rf "build/Small Mac Apps" && mkdir -p "build/Small Mac Apps"
for app in $APPS; do cp -R "build/$app.app" "build/Small Mac Apps/"; done
ditto -c -k --keepParent "build/Small Mac Apps" build/release/SmallMacApps.zip
echo "zips in build/release, screenshots in docs/screenshots"
