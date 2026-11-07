import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(MainActor.assumeIsolated { SelfTest.run() }) }
Desktop.handleSnapshot(title: "Invoice", size: CGSize(width: 1100, height: 720)) { MainActor.assumeIsolated { ContentView(model: .demo) } }
InvoiceApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct InvoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = InvoiceModel()

    var body: some Scene {
        Window("Invoice", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Invoice")
            CommandGroup(replacing: .newItem) {
                Button("New Invoice") { model.newInvoice() }.keyboardShortcut("n")
                Button("Duplicate Invoice") { model.duplicate() }.keyboardShortcut("d").disabled(model.selected == nil)
            }
            CommandGroup(replacing: .importExport) {
                Button("Export PDF…") { model.exportPDF() }.keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.selected == nil)
            }
            CommandGroup(replacing: .printItem) {
                Button("Print…") { model.print() }.keyboardShortcut("p").disabled(model.selected == nil)
            }
            CommandMenu("Invoice") {
                Button(model.selected?.isPaid == true ? "Mark as Unpaid" : "Mark as Paid") { model.togglePaid() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(model.selected == nil)
                Button("Use Current Business Details") { model.useCurrentBusinessDetails() }
                    .keyboardShortcut("u", modifiers: [.command, .option])
                    .disabled(!model.sellerIsOutdated)
                Divider()
                Button("Delete Invoice…") { confirmDelete() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selected == nil)
            }
            CommandGroup(after: .toolbar) {
                Picker("Paper Size", selection: $model.business.paper) {
                    Text("A4").tag(Paper.a4).keyboardShortcut("1")
                    Text("Letter").tag(Paper.letter).keyboardShortcut("2")
                }
                .pickerStyle(.inline)
                Divider()
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }

    @MainActor
    private func confirmDelete() {
        guard let invoice = model.selected else { return }
        let alert = NSAlert()
        alert.messageText = "Delete invoice \(invoice.number)?"
        alert.informativeText = "You can undo this with Edit > Undo."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.delete(undoManager: NSApp.keyWindow?.undoManager ?? NSApp.mainWindow?.undoManager)
    }
}

// MARK: - Icon

//: a crisp paper invoice with ruled lines, a totals bar and a big green check stamp over its corner

func appIcon() -> NSBitmapImageRep {
    render(0x2ECC8F, 0x0F7A55) { ctx in
        // The sheet, tilted slightly, with a folded top corner.
        ctx.saveGState()
        ctx.translateBy(x: 470, y: 520)
        ctx.rotate(by: 4 * .pi / 180)
        let sheet = CGRect(x: -215, y: -290, width: 430, height: 580)
        let fold: CGFloat = 92
        let outline = CGMutablePath()
        outline.move(to: CGPoint(x: sheet.minX + 26, y: sheet.minY))
        outline.addLine(to: CGPoint(x: sheet.maxX - 26, y: sheet.minY))
        outline.addQuadCurve(to: CGPoint(x: sheet.maxX, y: sheet.minY + 26), control: CGPoint(x: sheet.maxX, y: sheet.minY))
        outline.addLine(to: CGPoint(x: sheet.maxX, y: sheet.maxY - fold))
        outline.addLine(to: CGPoint(x: sheet.maxX - fold, y: sheet.maxY))
        outline.addLine(to: CGPoint(x: sheet.minX + 26, y: sheet.maxY))
        outline.addQuadCurve(to: CGPoint(x: sheet.minX, y: sheet.maxY - 26), control: CGPoint(x: sheet.minX, y: sheet.maxY))
        outline.addLine(to: CGPoint(x: sheet.minX, y: sheet.minY + 26))
        outline.addQuadCurve(to: CGPoint(x: sheet.minX + 26, y: sheet.minY), control: CGPoint(x: sheet.minX, y: sheet.minY))
        outline.closeSubpath()

        ctx.saveGState()
        shadow(ctx, y: -22, blur: 40, alpha: 0.32)
        ctx.addPath(outline)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(outline)
        ctx.clip()
        gradient([NSColor.white, rgb(0xEEF4F1)], from: CGPoint(x: 0, y: sheet.maxY), to: CGPoint(x: 0, y: sheet.minY), in: ctx)
        ctx.restoreGState()

        // Folded corner.
        let corner = CGMutablePath()
        corner.move(to: CGPoint(x: sheet.maxX - fold, y: sheet.maxY))
        corner.addLine(to: CGPoint(x: sheet.maxX - fold, y: sheet.maxY - fold + 14))
        corner.addQuadCurve(to: CGPoint(x: sheet.maxX - fold + 14, y: sheet.maxY - fold),
                            control: CGPoint(x: sheet.maxX - fold, y: sheet.maxY - fold))
        corner.addLine(to: CGPoint(x: sheet.maxX, y: sheet.maxY - fold))
        corner.closeSubpath()
        ctx.saveGState()
        shadow(ctx, y: -6, blur: 12, alpha: 0.18)
        ctx.addPath(corner)
        ctx.setFillColor(rgb(0xD5E3DC).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // Header bar and ruled lines.
        ctx.setLineCap(.round)
        ctx.setStrokeColor(rgb(0x0F7A55).cgColor)
        ctx.setLineWidth(34)
        ctx.move(to: CGPoint(x: sheet.minX + 62, y: sheet.maxY - 82))
        ctx.addLine(to: CGPoint(x: sheet.minX + 200, y: sheet.maxY - 82))
        ctx.strokePath()
        ctx.setStrokeColor(rgb(0xC9D6CF).cgColor)
        ctx.setLineWidth(16)
        for (i, w) in [CGFloat(290), 220, 260, 190].enumerated() {
            let y = sheet.maxY - 178 - CGFloat(i) * 62
            ctx.move(to: CGPoint(x: sheet.minX + 62, y: y))
            ctx.addLine(to: CGPoint(x: sheet.minX + 62 + w, y: y))
            ctx.strokePath()
        }
        // Totals bar.
        ctx.addPath(roundedRect(CGRect(x: sheet.minX + 170, y: sheet.minY + 66, width: 200, height: 46), 23))
        ctx.setFillColor(rgb(0x2ECC8F, 0.55).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // The check stamp, overlapping the lower right corner.
        let center = CGPoint(x: 655, y: 335)
        let radius: CGFloat = 168
        ctx.saveGState()
        shadow(ctx, y: -18, blur: 36, alpha: 0.38)
        ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        ctx.setFillColor(rgb(0x0B6A49).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        ctx.clip()
        gradient([rgb(0x3BE0A0), rgb(0x12925F)], from: CGPoint(x: 0, y: center.y + radius), to: CGPoint(x: 0, y: center.y - radius), in: ctx)
        radial([NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0)],
               center: CGPoint(x: center.x - 50, y: center.y + 80), radius: 170, in: ctx)
        ctx.restoreGState()
        // Inner ring, like a rubber stamp.
        ctx.addEllipse(in: CGRect(x: center.x - radius + 22, y: center.y - radius + 22, width: (radius - 22) * 2, height: (radius - 22) * 2))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(8)
        ctx.strokePath()
        // The check.
        ctx.saveGState()
        shadow(ctx, y: -6, blur: 10, alpha: 0.25)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(44)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.move(to: CGPoint(x: center.x - 72, y: center.y + 2))
        ctx.addLine(to: CGPoint(x: center.x - 18, y: center.y - 54))
        ctx.addLine(to: CGPoint(x: center.x + 80, y: center.y + 62))
        ctx.strokePath()
        ctx.restoreGState()
    }
}
