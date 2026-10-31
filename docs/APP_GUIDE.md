# How to add an app

The bar is "an app Sindre Sorhus or Panic would ship": native, small, one clear job, beautiful, no rough edges. Read `Sources/Jot/main.swift`, `Sources/Tempo/main.swift` and `Sources/Kit/*.swift` before writing your first app. Match their structure, naming and comment density.

## Files for an app called `Foo`

| File | Content |
|---|---|
| `Sources/Foo/main.swift` | Everything: entry point, model, SwiftUI views, `appIcon()`. Split into more files in `Sources/Foo/` only past ~600 lines. |
| `Apps/Foo/Info.plist` | Copy `Apps/Jot/Info.plist`; change name, executable, `com.weirdapps.foo`, the one-line description in `CFBundleGetInfoString` and the copyright line. Add usage-description keys only if the app truly needs them. |

Nothing else. `Package.swift` and `scripts/build.sh` discover apps by folder. **Never edit `Sources/Kit/`, `Package.swift`, `scripts/`, `README.md` or another app's folder**: other builders work in parallel and the lead merges by folder. If you need a helper, put it in your app's folder.

## Skeleton

```swift
import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusPopover!
    let model = FooModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "sf.symbol.name", accessibilityLabel: "Foo") {
            FooView().environmentObject(self.model)
        }
    }
}
```

Kit gives you: `StatusPopover` (menu bar item + popover, `setSymbol`, `setTitle` for monospaced text in the bar, `onSecondaryClick`, `toggle`), `HotKey(keyCode: kVK_ANSI_X, modifiers: cmdKey | optionKey)` (needs `import Carbon.HIToolbox`), `HUD.show(symbol:title:tint:)`, `PanelFooter(name:shortcut:) { menu items }` (always the bottom bar: settings menu, launch at login, about, quit), `KeyCap`, `GlassIconButton`, `PillButtonStyle(colors)`, `Storage.load/save` (JSON in Application Support), `VisualEffect`, `LinkCleaner`. Icon helpers: `render(top, bottom) { ctx in }`, `rgb(0xRRGGBB)`, `gradient`, `radial`, `shadow`, `roundedRect`, `sparkle`, and `tile` (the 824 px tile rect, origin 100,100, y up).

## Design rules

- Popover width 300 to 400 pt. Header with a bold rounded title or a big hero number, content, then `Divider().opacity(0.5)` and `PanelFooter`.
- System fonts; `.rounded` design for numbers and titles; `.monospacedDigit()` on anything that ticks.
- Rows: `RoundedRectangle(cornerRadius: 10-12, style: .continuous).fill(.quaternary.opacity(0.3))`, brighter on hover. Hover states and `.snappy`/spring animations on state changes. `contentTransition(.numericText())` for changing numbers.
- One accent gradient per app, shared by the icon and the UI.
- An empty state with an SF Symbol and one helpful sentence. Never a blank panel.
- Persist user data with `Storage` or `@AppStorage`. Nothing leaves the Mac unless the app's job is network data; then say so in the README row.
- No Accessibility, Screen Recording, Full Disk Access or Automation permissions. No private APIs, no `value(forKey:)` tricks.
- Global shortcuts only where they earn it, ⌥⌘ plus a letter. Do not reuse J, M, T (taken by Jot, Hush, Tempo); record your choice in your report.
- English UI text, plain words. No em or en dashes anywhere (code, comments, UI).

## Icon

`func appIcon() -> NSBitmapImageRep` at the end of `main.swift`, under `// MARK: - Icon`, drawn in Core Graphics with `render(top, bottom) { ctx in ... }`. Hand-crafted: a distinct, bold silhouette that reads at 32 px, a background gradient unlike the other apps, depth through soft shadows and highlights. No text, no SF Symbols in icons. See the five existing icons for the level of craft expected.

## Done means, per app

1. `swift build -c release --product Foo` has no errors and no warnings from your files.
2. `scripts/build.sh Foo` succeeds (it renders the icon and makes `build/Foo.app`).
3. `build/Foo.app/Contents/MacOS/Foo --snapshot /path/foo-panel.png` and Read that image. Also Read `build/icons/Foo.png`. Fix anything clipped, misaligned, empty or ugly, and look again. Snapshot rendering does not show vibrancy, which is fine.
4. If the app has logic that can be wrong (parsing, maths, conversions), test it: add a pure function and exercise it from a quick `swift` script or a check in your report. Do not add test targets.
5. `git add Sources/Foo Apps/Foo && git commit -m "Add Foo: <one line>"`, with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
6. Never run `scripts/build.sh --install`, never copy to /Applications, never launch apps with `open`. The lead installs after merging.
