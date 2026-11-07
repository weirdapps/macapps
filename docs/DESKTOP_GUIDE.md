# How to add a desktop app

The desktop apps are the windowed siblings of the menu bar apps: a Dock icon, a real window, a full main menu. Same bar: "an app Sindre Sorhus or Panic would ship". Native, small, one clear job, beautiful, no rough edges. It should feel like a utility Apple forgot to ship in /Applications/Utilities.

Read `docs/APP_GUIDE.md` (the menu bar contract; its icon, design, wording and commit rules all apply here too), `Sources/Kit/Desktop.swift`, `Sources/Kit/IconKit.swift`, `Sources/Kit/Components.swift`, and one menu app such as `Sources/Compare/main.swift` for code style, before writing.

## Files for an app called `Foo`

| File | Content |
|---|---|
| `Sources/Foo/main.swift` | Entry point, `FooApp`, `appIcon()` and, if short, everything else. Past ~600 lines split into `Model.swift`, `Views.swift`, `SelfTest.swift` in `Sources/Foo/`. |
| `Apps/Foo/Info.plist` | Copy `Apps/Jot/Info.plist`, **delete the `LSUIElement` line** (desktop apps have a Dock icon), change name, executable, `com.weirdapps.foo`, `CFBundleGetInfoString`, the copyright line and `LSApplicationCategoryType`. Document apps add `CFBundleDocumentTypes` (and `UTImportedTypeDeclarations` / `UTExportedTypeDeclarations` for their own types). Usage-description keys only if the app truly needs them. |

Never edit `Sources/Kit/`, `Package.swift`, `scripts/`, `README.md`, `docs/` or another app's folder.

## Skeleton

```swift
import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Foo", size: CGSize(width: 860, height: 560)) { ContentView(model: .demo) }
FooApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Single-window utilities quit when their window closes, like Calculator. Document apps do not.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct FooApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = FooModel()

    var body: some Scene {
        Window("Foo", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 860, height: 560)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Foo")
            CommandGroup(replacing: .newItem) { /* or after: the app's own File items with shortcuts */ }
        }
        // Settings { SettingsView() }   // only if the app has preferences; opens with ⌘,
    }
}
```

- `FooApp` is **not** marked `@main`; `main.swift` calls `FooApp.main()` after the command-line hooks.
- **Never declare a top-level `let` or `var` in `main.swift`.** Put constants in a type (`enum Theme { static let ... }`).
- Single-window tools use `Window`. Apps that open files the user owns (a text, a CSV, a database) use `DocumentGroup` with a `FileDocument`/`ReferenceFileDocument`, or a `WindowGroup(for: URL.self)` viewer, plus `CFBundleDocumentTypes` so Finder's Open With works. Pick what Apple would.
- `Desktop.handleSnapshot` renders the window for the website. It takes the same root view the window shows, fed with fixed demo data (`.demo`). It runs before the app exists, so the view must not depend on `@Environment(\.openWindow)` side effects, `NSApp.keyWindow` or real files. `Desktop.isSnapshot` is true then; never read or write the user's data, files, settings or clipboard under it. Pick the size the app looks best at (minimum 720×460, maximum 1100×720).
- `SelfTest.run() -> Int32` returns 0 when every check passes and prints `FAIL: ...` lines plus a summary otherwise. Every app has one. It exercises the pure logic: parsing, maths, conversions, file transforms (on temporary files it creates and deletes), game rules, persistence round trips. A UI-only app still checks its model. Aim for 10 to 40 meaningful checks.

## Mac conventions to get right

- A full, honest main menu: File items (New, Open ⌘O, Save/Export ⌘S/⇧⌘E, Close ⌘W comes free), Edit (undo where you edit things: use the `UndoManager` from the environment or `DocumentGroup`'s), View items for the app's modes with shortcuts, and `AppHelpCommands`. Every toolbar button has a menu item twin with a shortcut.
- Toolbar: SwiftUI `.toolbar` with SF Symbols and `.help` tooltips; `NavigationSplitView` when there is a list of things. Native controls (`Picker`, `Slider`, `Stepper`, `Toggle`, `Table`, `List`, `Form` with `.formStyle(.grouped)` for settings), not custom imitations.
- Files: drag and drop onto the window (`.dropDestination(for: URL.self)`), `.fileImporter` / `NSOpenPanel` and `.fileExporter` / `NSSavePanel`. Never overwrite a user's original unless they asked; write next to it with a suffix, or ask with a save panel. Offer Reveal in Finder after writing.
- Empty state: `DropZone` from Kit for file apps; otherwise an SF Symbol and one helpful sentence (`ContentUnavailableView` is fine). Never a blank window.
- Window remembers its size and position (SwiftUI does this). Sensible `.frame(minWidth:minHeight:)` so nothing clips when the window is small.
- Light and dark mode both look right: semantic colours (`.primary`, `.secondary`, `Color(nsColor: .controlBackgroundColor)`), accent gradient only on highlights.
- Long work (hashing a folder, resizing 200 images) runs off the main thread with a progress indicator and a cancel button; the UI never beachballs.
- Persist user data with `Storage` (JSON in Application Support) or `@AppStorage`. Nothing leaves the Mac unless network is the app's job.
- No Accessibility, Screen Recording, Full Disk Access or Automation permissions, no private APIs, no `value(forKey:)` tricks, no third-party packages, no web views. The microphone is allowed only where the app is about sound input, with `NSMicrophoneUsageDescription`.
- English UI text, plain words, sentence case for labels, title case for menu items (like Apple). No em or en dashes anywhere (code, comments, UI).

## Design

- One accent gradient per app, shared by the icon and the UI's highlights (selected states, the primary button, charts).
- System fonts; `.rounded` for big numbers and titles; `.monospacedDigit()` for anything that changes.
- Generous spacing, aligned edges, real hierarchy. Hover states and `.snappy` animations on state changes; `contentTransition(.numericText())` for changing numbers.
- The window should look finished at its default size with demo data: no huge empty areas, nothing cramped, nothing clipped.

## Icon

Same rules as `docs/APP_GUIDE.md`: `func appIcon() -> NSBitmapImageRep` at the end of `main.swift` under `// MARK: - Icon`, Core Graphics via `render(top, bottom) { ctx in }`, a bold distinct silhouette that reads at 32 px, depth through shadows and highlights, no text, no SF Symbols. It must not look like any icon in `docs/icons/` (look at a few).

## Done means, per app

1. `swift build -c release --manifest-cache none --product Foo`: no errors and no warnings from your files.
2. `scripts/build.sh Foo` succeeds.
3. `build/Foo.app/Contents/MacOS/Foo --selftest` prints all checks passing and exits 0.
4. `build/Foo.app/Contents/MacOS/Foo --snapshot <scratch>/Foo.png`, then Read the image, and Read `build/icons/Foo.png`. Fix anything clipped, misaligned, empty, cramped or ugly, and look again. Iterate until you would put it on a product page.
5. Launch smoke test: start `build/Foo.app/Contents/MacOS/Foo` in the background, wait 4 s, check it is still running (`pgrep -x Foo`), then `pkill -x Foo`. A crash on launch is a failed app.
6. `git add Sources/Foo Apps/Foo && git commit -m "Add Foo: <one line>"` with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
7. Never run `scripts/build.sh --install`, never copy to /Applications, never `open` an app. The lead installs after merging.
