import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(MainActor.assumeIsolated { SelfTest.run() }) }
Desktop.handleSnapshot(title: "On the Blank Page.md", size: CGSize(width: 960, height: 640)) { SnapshotView() }
DraftApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A document app: closing the last window leaves Draft running, like TextEdit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct DraftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var prefs = Prefs.shared

    var body: some Scene {
        DocumentGroup(newDocument: DraftDocument()) { file in
            DocumentWindow(document: file.$document, prefs: prefs)
        }
        .defaultSize(width: 900, height: 680)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            AppHelpCommands(name: "Draft")
            DraftCommands(prefs: prefs)
        }

        Settings { SettingsView(prefs: prefs) }
    }
}

/// Each window keeps its own writing session.
struct DocumentWindow: View {
    @Binding var document: DraftDocument
    @ObservedObject var prefs: Prefs
    @StateObject private var session = WritingSession()

    var body: some View {
        ContentView(text: $document.text, isMarkdown: document.isMarkdown, prefs: prefs, session: session)
            .focusedSceneObject(session)
    }
}

struct DraftCommands: Commands {
    @ObservedObject var prefs: Prefs
    @FocusedObject private var session: WritingSession?

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Menu("Focus") {
                choice("Off", prefs.focus == .off, "0") { prefs.focus = .off }
                choice("Paragraph", prefs.focus == .paragraph, "p") { prefs.focus = .paragraph }
                choice("Sentence", prefs.focus == .sentence, "s") { prefs.focus = .sentence }
            }
            Toggle("Typewriter Scrolling", isOn: $prefs.typewriter)
                .keyboardShortcut("t", modifiers: [.control, .command])
            Menu("Theme") {
                ForEach(Array(Theme.allCases.enumerated()), id: \.element) { i, theme in
                    choice(theme.label, prefs.theme == theme, KeyEquivalent(Character("\(i + 1)"))) { prefs.theme = theme }
                }
            }
            Menu("Typeface") {
                ForEach(Typeface.allCases) { face in
                    Toggle(face.label, isOn: Binding(get: { prefs.typeface == face }, set: { _ in prefs.typeface = face }))
                }
            }
            Divider()
            Button("Bigger") { prefs.bigger() }.keyboardShortcut("+")
            Button("Smaller") { prefs.smaller() }.keyboardShortcut("-")
            Button("Actual Size") { prefs.actualSize() }.keyboardShortcut("0")
            Divider()
            Button("Restart Session") { session?.restart() }
                .keyboardShortcut("r", modifiers: [.control, .command])
                .disabled(session == nil)
            Divider()
        }
    }

    private func choice(_ title: String, _ on: Bool, _ key: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { on }, set: { _ in action() }))
            .keyboardShortcut(key, modifiers: [.control, .command])
    }
}

/// The website screenshot: fixed text, Sepia, paragraph focus, a session part way to its goal.
struct SnapshotView: View {
    @StateObject private var prefs = Prefs.demo
    @StateObject private var session = WritingSession(baseline: TextStats(Demo.text).words - 312)

    var body: some View {
        ContentView(text: .constant(Demo.text), isMarkdown: true, prefs: prefs, session: session, initialCaret: Demo.caret)
    }
}

/// The text of the website screenshot.
enum Demo {
    static let text = """
    # On the Blank Page

    Every draft begins the same way: a cursor, an empty field, and the quiet suspicion that you have nothing to say. The trick is not to argue with that voice. You simply write the next sentence, and then the one after it.

    Good writing is mostly *rewriting*, but rewriting needs something to work on. So the first job is volume, not polish. Let the paragraph be clumsy. Let it wander. You will find the shape of the idea only once it exists outside your head, sitting on the page where you can push it around.

    That is why a goal helps. Five hundred words is small enough to start and big enough to matter. **Count the words, not the hours,** and stop while you still know what comes next, so tomorrow begins with momentum.

    > Write drunk on ideas; edit sober on structure.

    Tomorrow you will read this back and cut half of it. That is fine. That is the point.
    """

    /// On the second paragraph's first line, so the snapshot shows the title and first paragraph dimmed above it.
    static var caret: Int { (text as NSString).range(of: "needs something").location }
}

// MARK: - Icon

//: a fountain pen nib finishing a single line of ink on a warm page

func appIcon() -> NSBitmapImageRep {
    render(0xF5E6C8, 0xC9A46B) { ctx in
        // The page, tilted a little, with a soft shadow.
        ctx.saveGState()
        ctx.translateBy(x: 500, y: 500)
        ctx.rotate(by: -4 * .pi / 180)
        let page = CGRect(x: -280, y: -330, width: 560, height: 660)
        ctx.saveGState()
        shadow(ctx, y: -20, blur: 40, alpha: 0.26)
        ctx.addPath(roundedRect(page, 30))
        ctx.setFillColor(rgb(0xFFF9EC).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(roundedRect(page, 30))
        ctx.clip()
        gradient([rgb(0xFFFCF4), rgb(0xF6EAD0)], from: CGPoint(x: 0, y: page.maxY), to: CGPoint(x: 0, y: page.minY), in: ctx)
        // The single line of ink, slightly uneven like a real stroke.
        ctx.setStrokeColor(rgb(0x2A2118).cgColor)
        ctx.setLineCap(.round)
        ctx.setLineWidth(20)
        ctx.move(to: CGPoint(x: -210, y: -70))
        ctx.addCurve(to: CGPoint(x: -20, y: -64), control1: CGPoint(x: -150, y: -52), control2: CGPoint(x: -80, y: -82))
        ctx.addCurve(to: CGPoint(x: 104, y: -63), control1: CGPoint(x: 50, y: -52), control2: CGPoint(x: 80, y: -72))
        ctx.strokePath()
        ctx.restoreGState()

        // The nib: tip resting at the end of the line, body leaning up and to the right.
        ctx.saveGState()
        ctx.translateBy(x: 600, y: 430)
        ctx.rotate(by: -36 * .pi / 180)
        let s: CGFloat = 0.8
        ctx.scaleBy(x: s, y: s)
        let nib = CGMutablePath()
        nib.move(to: .zero)
        nib.addCurve(to: CGPoint(x: 128, y: 300), control1: CGPoint(x: 40, y: 60), control2: CGPoint(x: 112, y: 170))
        nib.addCurve(to: CGPoint(x: 104, y: 420), control1: CGPoint(x: 142, y: 360), control2: CGPoint(x: 126, y: 400))
        nib.addLine(to: CGPoint(x: -104, y: 420))
        nib.addCurve(to: CGPoint(x: -128, y: 300), control1: CGPoint(x: -126, y: 400), control2: CGPoint(x: -142, y: 360))
        nib.addCurve(to: .zero, control1: CGPoint(x: -112, y: 170), control2: CGPoint(x: -40, y: 60))
        nib.closeSubpath()

        // The grip section above the nib.
        let grip = roundedRect(CGRect(x: -122, y: 400, width: 244, height: 520), 40)
        ctx.saveGState()
        shadow(ctx, y: -16, blur: 30, alpha: 0.38)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(grip)
        ctx.setFillColor(rgb(0x2A2118).cgColor)
        ctx.fillPath()
        ctx.addPath(nib)
        ctx.setFillColor(rgb(0x2A2118).cgColor)
        ctx.fillPath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // Grip shading and a gold ring where it meets the nib.
        ctx.saveGState()
        ctx.addPath(grip)
        ctx.clip()
        gradient([rgb(0x4A3A2A), rgb(0x1C150F), rgb(0x3A2C1F)], from: CGPoint(x: -122, y: 0), to: CGPoint(x: 122, y: 0), in: ctx)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(roundedRect(CGRect(x: -126, y: 404, width: 252, height: 34), 14))
        ctx.clip()
        gradient([rgb(0xF2D28C), rgb(0xB8862F), rgb(0xE6C27A)], from: CGPoint(x: -126, y: 0), to: CGPoint(x: 126, y: 0), in: ctx)
        ctx.restoreGState()

        // Nib metal: a lit left facet and a shaded right one.
        ctx.saveGState()
        ctx.addPath(nib)
        ctx.clip()
        gradient([rgb(0x5A4733), rgb(0x2A2118)], from: CGPoint(x: -130, y: 380), to: CGPoint(x: 60, y: 60), in: ctx)
        ctx.clip(to: CGRect(x: 0, y: 0, width: 200, height: 440))
        gradient([rgb(0x241B13), rgb(0x150F0A)], from: CGPoint(x: 0, y: 400), to: CGPoint(x: 130, y: 100), in: ctx)
        ctx.restoreGState()
        // Gold edge highlight on the left shoulder.
        ctx.saveGState()
        ctx.addPath(nib)
        ctx.setStrokeColor(rgb(0xE6C27A, 0.55).cgColor)
        ctx.setLineWidth(5)
        ctx.strokePath()
        ctx.restoreGState()

        // Breather hole and slit, in page colour.
        ctx.setFillColor(rgb(0xF6E8CC).cgColor)
        ctx.fillEllipse(in: CGRect(x: -24, y: 236, width: 48, height: 48))
        ctx.setStrokeColor(rgb(0xF6E8CC).cgColor)
        ctx.setLineWidth(8)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 0, y: 238))
        ctx.addLine(to: CGPoint(x: 0, y: 26))
        ctx.strokePath()
        ctx.restoreGState()
    }
}
