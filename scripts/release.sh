#!/bin/zsh
# Builds every app, zips each bundle for a GitHub release, and refreshes the website's icons, screenshots and galleries.
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

# Menu bar apps have LSUIElement in their Info.plist; desktop apps do not.
MENU=() DESK=()
for app in $APPS; do
  if /usr/libexec/PlistBuddy -c "Print :LSUIElement" "Apps/$app/Info.plist" >/dev/null 2>&1; then MENU+=$app; else DESK+=$app; fi
done

bundle() {  # bundle <folder name> <zip name> apps...
  local dir="build/$1" zip="$2"; shift 2
  rm -rf "$dir" && mkdir -p "$dir"
  for app in "$@"; do cp -R "build/$app.app" "$dir/"; done
  ditto -c -k --keepParent "$dir" "build/release/$zip"
}
bundle "Small Mac Apps" SmallMacApps.zip $MENU
bundle "Mac Desktop Apps" MacDesktopApps.zip $DESK

# Icon galleries, in README order.
order() { grep -o 'docs/icons/[A-Za-z]*\.png' README.md | sed 's|docs/icons/||; s|\.png||' | awk '!s[$0]++'; }
menu_icons=() desk_icons=()
for app in $(order); do
  if (( ${MENU[(Ie)$app]} )); then menu_icons+="build/icons/$app.png"; elif (( ${DESK[(Ie)$app]} )); then desk_icons+="build/icons/$app.png"; fi
done
swift scripts/gallery.swift docs/icons.png $menu_icons
swift scripts/gallery.swift docs/icons-desktop.png $desk_icons
echo "zips in build/release, screenshots in docs/screenshots"
