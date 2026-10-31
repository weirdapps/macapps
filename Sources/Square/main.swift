import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Kit
import SwiftUI
import UniformTypeIdentifiers

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
    let model = SquareModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "qrcode", accessibilityLabel: "Square") {
            SquareView().environmentObject(self.model)
        }
    }
}

// MARK: - Model

enum Correction: String, CaseIterable, Identifiable {
    case L, M, Q, H

    var id: String { rawValue }
    var detail: String {
        switch self {
        case .L: "Recovers 7% damage"
        case .M: "Recovers 15% damage"
        case .Q: "Recovers 25% damage"
        case .H: "Recovers 30% damage"
        }
    }
}

enum QR {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// The code as a grid of modules, one pixel each, black on white, with no quiet zone.
    static func modules(_ text: String, correction: Correction) -> CGImage? {
        guard !text.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = correction.rawValue
        guard let output = filter.outputImage else { return nil }
        // Core Image adds a one module margin; crop it so the quiet zone is ours to size.
        let inner = output.extent.insetBy(dx: 1, dy: 1)
        return context.createCGImage(output, from: inner)
    }

    /// Renders crisp square modules at `size` pixels with a four module quiet zone, as the standard asks.
    static func image(_ text: String, correction: Correction, size: Int, foreground: CGColor, background: CGColor) -> CGImage? {
        guard let grid = modules(text, correction: correction) else { return nil }
        let count = grid.width + 8
        let scale = max(1, size / count)
        let side = scale * count
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        // Read the module grid, then paint each dark module as a square.
        guard let data = grid.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let bpp = grid.bitsPerPixel / 8, row = grid.bytesPerRow
        ctx.setFillColor(foreground)
        for y in 0..<grid.height {
            for x in 0..<grid.width where bytes[y * row + x * bpp] < 128 {
                // Image rows run top down; the context's y axis runs bottom up.
                ctx.fill(CGRect(x: (x + 4) * scale, y: (grid.height - 1 - y + 4) * scale, width: scale, height: scale))
            }
        }
        return ctx.makeImage()
    }

    /// Every QR code found in an image.
    static func read(_ image: CGImage) -> [String] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (detector?.features(in: CIImage(cgImage: image)) ?? []).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    /// WCAG contrast ratio of two sRGB colours, 1 to 21.
    static func contrast(_ a: CGColor, _ b: CGColor) -> Double {
        func luminance(_ c: CGColor) -> Double {
            let rgb = (c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0])
                .prefix(3).map { v -> Double in
                    let v = Double(v)
                    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
                }
            return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
        }
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}

@MainActor
final class SquareModel: ObservableObject {
    @Published var text = "https://weirdapps.github.io"
    @Published private(set) var decoded: [String]?
    @AppStorage("correction") var correctionRaw = Correction.M.rawValue
    @AppStorage("size") var size = 1024
    @AppStorage("foreground") var foregroundHex = "111827"
    @AppStorage("background") var backgroundHex = "FFFFFF"

    var correction: Correction {
        get { Correction(rawValue: correctionRaw) ?? .M }
        set { correctionRaw = newValue.rawValue }
    }

    var foreground: Color {
        get { Color(hex: foregroundHex) }
        set { foregroundHex = newValue.hex }
    }

    var background: Color {
        get { Color(hex: backgroundHex) }
        set { backgroundHex = newValue.hex }
    }

    var image: CGImage? {
        QR.image(text, correction: correction, size: size,
                 foreground: NSColor(foreground).cgColor, background: NSColor(background).cgColor)
    }

    var lowContrast: Bool { QR.contrast(NSColor(foreground).cgColor, NSColor(background).cgColor) < 3 }

    var nsImage: NSImage? {
        image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }

    func copyImage() {
        guard let nsImage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([nsImage])
    }

    func save() {
        guard let image else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "QR Code.png"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    func read(_ image: NSImage) {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { decoded = []; return }
        withAnimation(.snappy) { decoded = QR.read(cg) }
    }

    func readClipboard() {
        if let image = NSImage(pasteboard: .general) { read(image) } else { withAnimation(.snappy) { decoded = [] } }
    }

    func dismissDecoded() { withAnimation(.snappy) { decoded = nil } }
}

extension Color {
    init(hex: String) {
        let v = UInt32(hex, radix: 16) ?? 0
        self.init(.sRGB, red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}

// MARK: - Views

struct SquareView: View {
    @EnvironmentObject var model: SquareModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Square").font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer()
                Text("Drop an image to read a code").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            VStack(spacing: 10) {
                if let decoded = model.decoded { DecodedBanner(results: decoded).transition(.move(edge: .top).combined(with: .opacity)) }
                InputPane()
                Preview()
                Controls()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            Divider().opacity(0.5)
            PanelFooter(name: "Square") {
                Picker("Image Size", selection: $model.size) {
                    ForEach([256, 512, 1024, 2048], id: \.self) { Text("\($0) pixels").tag($0) }
                }
                Divider()
                Button("Read Code from Clipboard Image") { model.readClipboard() }
                Button("Reset Colours") { model.foregroundHex = "111827"; model.backgroundHex = "FFFFFF" }
            }
        }
        .frame(width: 360)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentTint, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentTint.opacity(0.1)))
                    .overlay(Label("Drop to read the QR code", systemImage: "qrcode.viewfinder")
                        .font(.system(size: 15, weight: .semibold, design: .rounded)))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.image, .fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage else { return }
                    let box = UncheckedBox(image)
                    DispatchQueue.main.async { model.read(box.value) }
                }
                return true
            }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let image = NSImage(contentsOf: url) else { return }
                let box = UncheckedBox(image)
                DispatchQueue.main.async { model.read(box.value) }
            }
            return true
        }
        .animation(.snappy(duration: 0.2), value: dropTargeted)
    }
}

/// Carries an image across to the main queue from a drop callback.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

struct DecodedBanner: View {
    @EnvironmentObject var model: SquareModel
    let results: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(results.isEmpty ? "No QR code found in that image." : "Read \(results.count) code\(results.count == 1 ? "" : "s")",
                      systemImage: results.isEmpty ? "exclamationmark.triangle.fill" : "qrcode.viewfinder")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(results.isEmpty ? Color.orange : Color.accentTint)
                Spacer()
                Button { model.dismissDecoded() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
            }
            ForEach(Array(results.enumerated()), id: \.offset) { _, value in
                HStack(spacing: 6) {
                    Text(value).font(.system(size: 12, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    PaneButton("doc.on.doc", "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                    }
                    PaneButton("arrow.down", "Use") { model.text = value; model.dismissDecoded() }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentTint.opacity(0.1)))
    }
}

struct InputPane: View {
    @EnvironmentObject var model: SquareModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text("\(model.text.utf8.count) bytes").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                PaneButton("doc.on.clipboard", "Paste") { model.text = NSPasteboard.general.string(forType: .string) ?? "" }
                PaneButton("xmark", "Clear") { model.text = "" }
            }
            TextEditor(text: $model.text)
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: 58)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
        }
    }
}

struct Preview: View {
    @EnvironmentObject var model: SquareModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.quaternary.opacity(0.3))
            if let image = model.nsImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 196, height: 196)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                    .onDrag { NSItemProvider(object: image) }
                    .help("Drag the code into another app")
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "qrcode").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text(model.text.isEmpty ? "Type or paste text to make a code." : "Too long for a QR code at level \(model.correction.rawValue).")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
            }
        }
        .frame(height: 220)
    }
}

struct Controls: View {
    @EnvironmentObject var model: SquareModel
    @State private var copied = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(Correction.allCases) { level in
                        let selected = model.correction == level
                        Button { withAnimation(.snappy) { model.correction = level } } label: {
                            Text(level.rawValue)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(selected ? .white : .secondary)
                                .frame(width: 26, height: 22)
                                .background(Capsule().fill(selected ? AnyShapeStyle(Color.accentGradient) : AnyShapeStyle(.clear)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(level.detail)
                    }
                }
                .padding(2.5)
                .background(Capsule().fill(.quaternary.opacity(0.5)))
                Spacer()
                ColorPicker("Code", selection: $model.foreground, supportsOpacity: false)
                ColorPicker("Back", selection: $model.background, supportsOpacity: false)
            }
            .font(.system(size: 11.5, weight: .medium))
            if model.lowContrast {
                Label("Low contrast. Some scanners may not read this code.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                Button {
                    model.copyImage()
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copied = false } }
                } label: {
                    Label(copied ? "Copied" : "Copy Image", systemImage: copied ? "checkmark" : "doc.on.doc").frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle([Color(red: 0.25, green: 0.27, blue: 0.32), Color(red: 0.07, green: 0.09, blue: 0.15)]))
                Button { model.save() } label: {
                    Label("Save PNG", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle([Color(red: 0.25, green: 0.27, blue: 0.32), Color(red: 0.07, green: 0.09, blue: 0.15)]))
            }
            .disabled(model.image == nil)
        }
    }
}

struct PaneButton: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    init(_ symbol: String, _ title: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(.quaternary.opacity(hovering ? 0.8 : 0.4)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
    }
}

extension Color {
    static let accentTint = Color(red: 0.2, green: 0.45, blue: 0.95)
    static let accentGradient = LinearGradient(colors: [Color(red: 0.3, green: 0.32, blue: 0.38), Color(red: 0.07, green: 0.09, blue: 0.15)],
                                               startPoint: .top, endPoint: .bottom)
}

// MARK: - Icon

//: a real, scannable QR code on paper, with one finder pattern in the accent colour

func appIcon() -> NSBitmapImageRep {
    render(0xFAFAF9, 0xD6D3D1) { ctx in
        let card = CGRect(x: 222, y: 222, width: 580, height: 580)
        ctx.saveGState()
        shadow(ctx, y: -16, blur: 34, alpha: 0.22)
        ctx.addPath(roundedRect(card, 60))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        guard let grid = QR.modules("SQUARE", correction: .L), let data = grid.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return }
        let n = grid.width
        let inner = card.insetBy(dx: 64, dy: 64)
        let m = inner.width / CGFloat(n)
        let bpp = grid.bitsPerPixel / 8
        func dark(_ x: Int, _ y: Int) -> Bool { bytes[y * grid.bytesPerRow + x * bpp] < 128 }
        func inFinder(_ x: Int, _ y: Int) -> Bool { (x < 7 && y < 7) || (x >= n - 7 && y < 7) || (x < 7 && y >= n - 7) }
        // Data modules as soft rounded dots.
        ctx.setFillColor(rgb(0x1C1917).cgColor)
        for y in 0..<n {
            for x in 0..<n where dark(x, y) && !inFinder(x, y) {
                let r = CGRect(x: inner.minX + CGFloat(x) * m, y: inner.maxY - CGFloat(y + 1) * m, width: m, height: m).insetBy(dx: m * 0.06, dy: m * 0.06)
                ctx.addPath(roundedRect(r, m * 0.3))
            }
        }
        ctx.fillPath()
        // Finder patterns drawn as rounded rings.
        for (fx, fy, color) in [(0, 0, 0x1C1917), (n - 7, 0, 0x1C1917), (0, n - 7, 0x2563EB)] as [(Int, Int, UInt32)] {
            let outer = CGRect(x: inner.minX + CGFloat(fx) * m, y: inner.maxY - CGFloat(fy + 7) * m, width: 7 * m, height: 7 * m)
            ctx.setFillColor(rgb(UInt32(color)).cgColor)
            ctx.addPath(roundedRect(outer, m * 1.8))
            ctx.addPath(roundedRect(outer.insetBy(dx: m, dy: m), m * 1.1))
            ctx.fillPath(using: .evenOdd)
            ctx.addPath(roundedRect(outer.insetBy(dx: 2 * m, dy: 2 * m), m * 0.8))
            ctx.fillPath()
        }
    }
}
