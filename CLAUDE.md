# macapps

Fifty native macOS menu bar apps and fifty desktop apps in one SwiftPM package. README.md lists them; docs/APP_GUIDE.md (menu bar) and docs/DESKTOP_GUIDE.md (desktop) are the contracts for adding one. Desktop apps have no LSUIElement; release.sh and selftest.sh tell them apart that way.

- Build and install: `scripts/build.sh [--install] [App ...]` (ad hoc signed, copies to /Applications, kills running copies first).
- Package.swift discovers apps by folder, so always pass `--manifest-cache none` to `swift build`; a cached manifest misses new folders.
- Tests: `swift test` (LinkCleaner only).
- Apps are AppKit status items hosting SwiftUI (`Kit/StatusPopover`), not `MenuBarExtra`, so hot keys can open the panel.
- Running a binary outside its `.app` crashes Tempo (UNUserNotificationCenter needs a bundle). Use `build/<App>.app/Contents/MacOS/<App>`.
- Screenshots: `<App> --snapshot out.png`. Icons: each app's `appIcon()`, rendered by `<App> --icon out.png` in the build script.
- Public at github.com/weirdapps/macapps; the website is `docs/` on GitHub Pages. Release: `scripts/release.sh`, then `gh release create vX.Y.Z build/release/*.zip`.
- `--snapshot` must render fixed demo data (`StatusPopover.isSnapshot`), never the Mac's real clipboard, files, IPs, processes or settings: the screenshots are published.
