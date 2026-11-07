#!/bin/zsh
# Runs `--selftest` for every desktop app (Info.plist without LSUIElement) already built in build/.
# Usage: scripts/selftest.sh [App ...]
set -uo pipefail
cd "${0:A:h}/.."
if (( $# )); then APPS=("$@"); else APPS=(Apps/*/Info.plist(:h:t)); fi
failed=()
for app in $APPS; do
  /usr/libexec/PlistBuddy -c "Print :LSUIElement" "Apps/$app/Info.plist" >/dev/null 2>&1 && continue
  if out=$(perl -e "alarm 120; exec @ARGV" "build/$app.app/Contents/MacOS/$app" --selftest 2>&1); then
    echo "pass $app: ${${(f)out}[-1]}"
  else
    echo "FAIL $app"; echo "$out" | grep -i fail | head -5; failed+=$app
  fi
done
(( ${#failed} )) && { echo "failed: $failed"; exit 1; }
echo "all self-tests passed"
