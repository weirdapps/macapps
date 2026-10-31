# macapps

Fifty native macOS menu bar apps in one SwiftPM package. README.md lists them; docs/APP_GUIDE.md is the contract for adding one.

- Build and install: `scripts/build.sh [--install] [App ...]` (ad hoc signed, copies to /Applications, kills running copies first).
- Package.swift discovers apps by folder, so always pass `--manifest-cache none` to `swift build`; a cached manifest misses new folders.
- Tests: `swift test` (LinkCleaner only).
- Apps are AppKit status items hosting SwiftUI (`Kit/StatusPopover`), not `MenuBarExtra`, so hot keys can open the panel.
- Running a binary outside its `.app` crashes Tempo (UNUserNotificationCenter needs a bundle). Use `build/<App>.app/Contents/MacOS/<App>`.
- Screenshots: `<App> --snapshot out.png`. Icons: each app's `appIcon()`, rendered by `<App> --icon out.png` in the build script.
- Not pushed anywhere yet. Publishing to GitHub (public) needs the owner's go-ahead.
