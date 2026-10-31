#!/bin/zsh
# Builds every app as a signed .app bundle in build/, and with --install copies them to /Applications.
set -euo pipefail
cd "${0:A:h}/.."

APPS=(Jot Meridian Hush Plain Tempo)

swift build -c release --product IconGen >/dev/null
.build/release/IconGen build/icons >/dev/null

for app in $APPS; do
  swift build -c release --product "$app"
  bundle="build/$app.app"
  rm -rf "$bundle"
  mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
  cp ".build/release/$app" "$bundle/Contents/MacOS/$app"
  cp "Apps/$app/Info.plist" "$bundle/Contents/Info.plist"

  iconset="build/icons/$app.iconset"
  rm -rf "$iconset" && mkdir -p "$iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "build/icons/$app.png" --out "$iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "build/icons/$app.png" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$bundle/Contents/Resources/AppIcon.icns"

  codesign --force --sign - --timestamp=none "$bundle"
  echo "built $bundle"
done

if [[ "${1:-}" == "--install" ]]; then
  for app in $APPS; do
    pkill -x "$app" 2>/dev/null || true
    rm -rf "/Applications/$app.app"
    cp -R "build/$app.app" "/Applications/$app.app"
    echo "installed /Applications/$app.app"
  done
fi
