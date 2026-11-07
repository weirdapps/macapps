import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Info.plist", size: CGSize(width: 900, height: 526)) {
    let (document, editor) = MainActor.assumeIsolated { Demo.make() }
    ContentView(document: document, fileURL: nil, editor: editor)
}
PlistApp.main()

struct PlistApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { PlistDocument() }) { file in
            ContentView(document: file.document, fileURL: file.fileURL)
        }
        .defaultSize(width: 900, height: 580)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Plist")
            EditorCommands()
        }
    }
}

struct EditorCommands: Commands {
    @FocusedObject private var editor: Editor?

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button("Export…") { editor?.export() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(editor == nil)
        }
        CommandGroup(before: .toolbar) {
            Button("Outline") { editor?.mode = .outline }
                .keyboardShortcut("1")
                .disabled(editor == nil)
            Button("Source") { editor?.mode = .source }
                .keyboardShortcut("2")
                .disabled(editor == nil)
            Divider()
            Button("Expand All") { editor?.mode = .outline; editor?.expandAll() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                .disabled(editor == nil)
            Button("Collapse All") { editor?.mode = .outline; editor?.collapseAll() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
                .disabled(editor == nil)
            Button("Filter Items") { editor?.mode = .outline; editor?.searchFocused = true }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(editor == nil)
            Divider()
        }
        CommandMenu("Editor") {
            Button("Add Item") { editor?.addItem() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(editor == nil)
            Button("Delete Item") { editor?.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .disabled(!(editor?.canDelete ?? false))
            Divider()
            Button("Move Up") { editor?.move(by: -1) }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(!(editor?.canMoveUp ?? false))
            Button("Move Down") { editor?.move(by: 1) }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(!(editor?.canMoveDown ?? false))
            Divider()
            if let editor, !editor.document.isJSON {
                Picker("Save Format", selection: Binding(get: { editor.document.format }, set: { editor.document.setFormat($0) })) {
                    Text("XML Property List").tag(FileFormat.xml)
                    Text("Binary Property List").tag(FileFormat.binary)
                }
            } else {
                Button("Save Format: JSON") {}.disabled(true)
            }
        }
    }
}

// MARK: - Demo

/// A small Info.plist for the website screenshot.
@MainActor
enum Demo {
    static func make() -> (PlistDocument, Editor) {
        func n(_ key: String, _ value: PValue) -> PNode { PNode(key: key, value: value) }
        let types = n("LSItemContentTypes", .array([n("", .string("com.apple.property-list")), n("", .string("public.json"))]))
        let docType = n("", .dictionary([
            n("CFBundleTypeName", .string("Property List")),
            n("CFBundleTypeRole", .string("Editor")),
            types,
            n("LSHandlerRank", .string("Alternate")),
        ]))
        let docTypes = n("CFBundleDocumentTypes", .array([docType]))
        let role = docType.children![1]
        let root = PNode(key: "Root", value: .dictionary([
            n("CFBundleDisplayName", .string("Plist")),
            n("CFBundleIdentifier", .string("com.weirdapps.plist")),
            n("CFBundleShortVersionString", .string("1.0.0")),
            n("CFBundleVersion", .integer(42)),
            docTypes,
            n("LSMinimumSystemVersion", .string("14.0")),
            n("NSHighResolutionCapable", .boolean(true)),
            n("NSSupportsAutomaticTermination", .boolean(false)),
            n("BuildDate", .date(Date(timeIntervalSince1970: 1_793_268_000))),
            n("WindowScale", .real(1.25)),
            n("SigningHash", .data(Data([0x9f, 0x3c, 0x7a, 0x11, 0xe4, 0x58, 0x02, 0xbd, 0x6e, 0xc1, 0x44, 0x90]))),
            n("NSHumanReadableCopyright", .string("© 2026 Dimitrios Plessas")),
        ]))
        let document = PlistDocument(root: root)
        let editor = Editor(document: document)
        editor.expanded = [docTypes.id, docType.id]
        editor.selection = role.id
        editor.fileName = "Info.plist"
        return (document, editor)
    }
}

// MARK: - Icon

//: a sheet of nested key and value rows, its corner notched around a gear

func appIcon() -> NSBitmapImageRep {
    render(0x8FA3BF, 0x4A5A75) { ctx in
        let sheet = CGRect(x: 226, y: 172, width: 556, height: 664)
        let gear = CGPoint(x: 734, y: 782)
        let everywhere = CGRect(x: 0, y: 0, width: iconSize, height: iconSize)

        // Sheet, with a round notch where the gear sits.
        ctx.saveGState()
        ctx.addRect(everywhere)
        ctx.addEllipse(in: CGRect(x: gear.x - 156, y: gear.y - 156, width: 312, height: 312))
        ctx.clip(using: .evenOdd)
        ctx.saveGState()
        shadow(ctx, y: -18, blur: 36, alpha: 0.32)
        ctx.addPath(roundedRect(sheet, 56))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(roundedRect(sheet, 56))
        ctx.clip()
        gradient([rgb(0xFFFFFF), rgb(0xE6EBF2)], from: CGPoint(x: 0, y: sheet.maxY), to: CGPoint(x: 0, y: sheet.minY), in: ctx)

        // Rows: (indent level, is a container, key length, value length).
        let rows: [(Int, Bool, CGFloat, CGFloat)] = [(0, true, 170, 0), (1, false, 120, 112), (1, true, 150, 0),
                                                     (2, false, 96, 120), (2, false, 126, 88), (0, false, 118, 170)]
        let left = sheet.minX + 62, step: CGFloat = 92, indent: CGFloat = 62
        func y(_ i: Int) -> CGFloat { sheet.maxY - 92 - CGFloat(i) * step }
        func x(_ level: Int) -> CGFloat { left + CGFloat(level) * indent }

        // Selected row band.
        ctx.addPath(roundedRect(CGRect(x: sheet.minX + 26, y: y(3) - 34, width: sheet.width - 52, height: 68), 22))
        ctx.setFillColor(rgb(0xD3DDEA).cgColor)
        ctx.fillPath()

        // Tree connectors from each container to its children.
        ctx.setStrokeColor(rgb(0xC2CCDA).cgColor)
        ctx.setLineWidth(7)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for (parent, children) in [(0, [1, 2]), (2, [3, 4])] {
            let px = x(rows[parent].0)
            ctx.move(to: CGPoint(x: px, y: y(parent) - 26))
            ctx.addLine(to: CGPoint(x: px, y: y(children.last!)))
            for c in children {
                ctx.move(to: CGPoint(x: px, y: y(c)))
                ctx.addLine(to: CGPoint(x: x(rows[c].0) - 20, y: y(c)))
            }
        }
        ctx.strokePath()

        for (i, row) in rows.enumerated() {
            let cy = y(i), mx = x(row.0)
            if row.1 {
                // An open disclosure triangle.
                ctx.move(to: CGPoint(x: mx - 17, y: cy + 11))
                ctx.addLine(to: CGPoint(x: mx + 17, y: cy + 11))
                ctx.addLine(to: CGPoint(x: mx, y: cy - 14))
                ctx.closePath()
                ctx.setFillColor(rgb(0x334155).cgColor)
                ctx.fillPath()
            } else {
                ctx.addEllipse(in: CGRect(x: mx - 10, y: cy - 10, width: 20, height: 20))
                ctx.setFillColor(rgb(0x8A9AB2).cgColor)
                ctx.fillPath()
            }
            let keyRect = CGRect(x: mx + 34, y: cy - 16, width: row.2, height: 32)
            ctx.addPath(roundedRect(keyRect, 16))
            ctx.setFillColor(rgb(i == 3 ? 0x2B3950 : 0x3E4C64).cgColor)
            ctx.fillPath()
            if row.3 > 0 {
                let valueRect = CGRect(x: keyRect.maxX + 26, y: cy - 16, width: row.3, height: 32)
                ctx.saveGState()
                ctx.addPath(roundedRect(valueRect, 16))
                ctx.clip()
                gradient([rgb(0x8FA3BF), rgb(0x5E7396)], from: CGPoint(x: valueRect.minX, y: 0), to: CGPoint(x: valueRect.maxX, y: 0), in: ctx)
                ctx.restoreGState()
            }
        }
        ctx.restoreGState()

        // Gear: a ring of teeth around a hub with a hole.
        let teeth = 8
        let body = CGMutablePath()
        body.addEllipse(in: CGRect(x: gear.x - 104, y: gear.y - 104, width: 208, height: 208))
        for t in 0..<teeth {
            let a = CGFloat(t) / CGFloat(teeth) * 2 * .pi + .pi / 8
            let transform = CGAffineTransform(translationX: gear.x, y: gear.y).rotated(by: a)
            body.addPath(roundedRect(CGRect(x: 72, y: -26, width: 64, height: 52), 12), transform: transform)
        }
        ctx.saveGState()
        ctx.addRect(everywhere)
        ctx.addEllipse(in: CGRect(x: gear.x - 42, y: gear.y - 42, width: 84, height: 84))
        ctx.clip(using: .evenOdd)
        ctx.saveGState()
        shadow(ctx, y: -12, blur: 26, alpha: 0.35)
        ctx.addPath(body)
        ctx.setFillColor(rgb(0x3A475E).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(body)
        ctx.clip()
        gradient([rgb(0x6F82A1), rgb(0x2C374B)], from: CGPoint(x: 0, y: gear.y + 136), to: CGPoint(x: 0, y: gear.y - 136), in: ctx)
        ctx.addEllipse(in: CGRect(x: gear.x - 70, y: gear.y - 70, width: 140, height: 140))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
        ctx.setLineWidth(8)
        ctx.strokePath()
        ctx.restoreGState()
    }
}
