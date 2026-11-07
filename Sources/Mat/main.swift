import AppKit
import Kit
import SwiftUI
import UniformTypeIdentifiers

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Mat", size: CGSize(width: 1040, height: 660)) { MainActor.assumeIsolated { ContentView(model: .demo) } }
MatApp.main()

enum Theme {
    static let top = Color(red: 1, green: 0x7A / 255, blue: 0x59 / 255)
    static let bottom = Color(red: 0xD9 / 255, green: 0x34 / 255, blue: 0x5F / 255)
    static let gradient = LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single window utility: closing the window quits, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct MatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = MatModel()

    var body: some Scene {
        Window("Mat", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1040, height: 660)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Mat")
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.open() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Export PNG…") { model.export() }.keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!model.hasImage)
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Copy Image") { model.copy() }.keyboardShortcut("c").disabled(!model.hasImage)
                Button("Paste") { model.paste() }.keyboardShortcut("v")
            }
            CommandMenu("Style") {
                Button("Next Background") { model.update("Change Background") { $0.backdrop = $0.backdrop.stepped(by: 1) } }
                    .keyboardShortcut("]")
                Button("Previous Background") { model.update("Change Background") { $0.backdrop = $0.backdrop.stepped(by: -1) } }
                    .keyboardShortcut("[")
                Divider()
                Toggle("Window Border", isOn: Binding(get: { model.style.border },
                                                       set: { v in model.update("Window Border") { $0.border = v } }))
                    .keyboardShortcut("b")
                Divider()
                ForEach(Array(Aspect.allCases.enumerated()), id: \.element) { i, aspect in
                    Toggle(aspect.title, isOn: Binding(get: { model.style.aspect == aspect },
                                                       set: { _ in model.update("Change Aspect") { $0.aspect = aspect } }))
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
                Divider()
                ForEach([1, 2], id: \.self) { scale in
                    Toggle("Export at \(scale)x", isOn: Binding(get: { model.style.scale == scale },
                                                              set: { _ in model.update("Export Scale") { $0.scale = scale } }))
                }
                Divider()
                Button("Reset Style") { model.update("Reset Style") { $0 = MatStyle() } }
            }
        }
    }
}

// MARK: - Window

struct ContentView: View {
    @ObservedObject var model: MatModel
    @Environment(\.undoManager) private var undoManager
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 0) {
            canvas
            Divider()
            Inspector(model: model)
                .frame(width: 300)
        }
        .frame(minWidth: 780, minHeight: 500)
        .onDrop(of: [.fileURL, .image], isTargeted: $targeted) { model.handleDrop($0) }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
        .toolbar {
            ToolbarItemGroup {
                Button { model.open() } label: { Label("Open", systemImage: "folder") }
                    .help("Open a screenshot (⌘O)")
                Button { model.paste() } label: { Label("Paste", systemImage: "clipboard") }
                    .help("Paste a screenshot from the clipboard (⌘V)")
                Button { model.copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .help("Copy the finished image (⌘C)")
                    .disabled(!model.hasImage)
                Button { model.export() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .help("Export a PNG (⇧⌘E)")
                    .disabled(!model.hasImage)
            }
        }
        .navigationTitle(model.hasImage ? model.sourceName : "Mat")
    }

    private var canvas: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .windowBackgroundColor).overlay(Color.primary.opacity(0.05))
                if let preview = model.preview {
                    Image(nsImage: preview)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                        .padding(34)
                        .overlay {
                            if targeted {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Theme.gradient, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                                    .padding(16)
                            }
                        }
                        .animation(.snappy(duration: 0.25), value: model.style)
                } else {
                    DropZone(symbol: "photo.on.rectangle.angled", title: "Drop a screenshot",
                             message: "Or paste one with ⌘V. Take one with ⌃⇧⌘4 to send it straight to the clipboard.",
                             button: "Open Image…", tint: Theme.bottom, isTargeted: targeted) { model.open() }
                }
            }
            .overlay(alignment: .bottom) { toastView }
            Divider()
            statusBar
        }
        .frame(minWidth: 460)
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = model.toast {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.gradient)
                Text(toast.text).font(.system(size: 12.5, weight: .medium))
                if let file = toast.file {
                    Button("Show in Finder") { revealInFinder([file]) }
                        .buttonStyle(.link)
                        .font(.system(size: 12.5, weight: .medium))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.quaternary))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .padding(.bottom, 14)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let source = model.source, let layout = model.layout {
                Image(systemName: "photo").foregroundStyle(.tertiary)
                Text("\(source.width) × \(source.height)")
                    .monospacedDigit()
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                let px = layout.pixels(scale: model.style.scale)
                Text("\(Int(px.width)) × \(Int(px.height)) PNG")
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.primary)
                Text("at \(model.style.scale)x").foregroundStyle(.tertiary)
            } else {
                Text("No image").foregroundStyle(.tertiary)
            }
            Spacer()
            Text(model.style.aspect.title).foregroundStyle(.tertiary)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .animation(.snappy, value: model.style)
    }
}

// MARK: - Inspector

struct Inspector: View {
    @ObservedObject var model: MatModel

    var body: some View {
        Form {
            Section("Background") {
                VStack(alignment: .leading, spacing: 10) {
                    swatchRow(Array(Presets.gradients.indices.prefix(5)).map { Backdrop.gradient($0) })
                    swatchRow(Array(Presets.gradients.indices.dropFirst(5)).map { Backdrop.gradient($0) })
                    swatchRow(Presets.solids.indices.map { Backdrop.solid($0) })
                    HStack(spacing: 10) {
                        Swatch(backdrop: .custom, style: model.style, selected: model.style.backdrop == .custom) {
                            model.update("Change Background") { $0.backdrop = .custom }
                        }
                        Text("Custom").foregroundStyle(.secondary)
                        Spacer()
                        ColorPicker("Top", selection: colorBinding(\.customTop), supportsOpacity: false).labelsHidden()
                            .controlSize(.small).help("Top left colour")
                        ColorPicker("Bottom", selection: colorBinding(\.customBottom), supportsOpacity: false).labelsHidden()
                            .controlSize(.small).help("Bottom right colour")
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Frame") {
                slider("Padding", value: \.padding, in: 0...0.25, text: "\(Int((model.style.padding * 100).rounded()))%")
                slider("Corners", value: \.radius, in: 0...40, text: "\(Int(model.style.radius.rounded()))")
                slider("Shadow", value: \.shadow, in: 0...1, text: "\(Int((model.style.shadow * 100).rounded()))%")
                Toggle("Window border", isOn: Binding(get: { model.style.border },
                                                      set: { v in model.update("Window Border") { $0.border = v } }))
                    .tint(Theme.bottom)
            }
            Section("Output") {
                Picker("Aspect", selection: Binding(get: { model.style.aspect },
                                                    set: { v in model.update("Change Aspect") { $0.aspect = v } })) {
                    ForEach(Aspect.allCases) { Text($0.title).tag($0) }
                }
                Picker("Scale", selection: Binding(get: { model.style.scale },
                                                   set: { v in model.update("Export Scale") { $0.scale = v } })) {
                    Text("1x").tag(1)
                    Text("2x").tag(2)
                }
                .pickerStyle(.segmented)
                HStack(spacing: 10) {
                    Button { model.copy() } label: {
                        Label("Copy", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    Button { model.export() } label: {
                        Label("Export…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.bottom)
                }
                .disabled(!model.hasImage)
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func swatchRow(_ items: [Backdrop]) -> some View {
        HStack(spacing: 10) {
            ForEach(items, id: \.self) { backdrop in
                Swatch(backdrop: backdrop, style: model.style, selected: model.style.backdrop == backdrop) {
                    model.update("Change Background") { $0.backdrop = backdrop }
                }
            }
        }
    }

    private func colorBinding(_ key: WritableKeyPath<MatStyle, RGB>) -> Binding<Color> {
        Binding(get: { model.style[keyPath: key].color },
                set: { color in model.update("Change Colour") { $0[keyPath: key] = RGB(color); $0.backdrop = .custom } })
    }

    private func slider(_ title: String, value: WritableKeyPath<MatStyle, Double>, in range: ClosedRange<Double>,
                        text: String) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 62, alignment: .leading)
            Slider(value: Binding(get: { model.style[keyPath: value] }, set: { model.style[keyPath: value] = $0 }), in: range) {
                model.sliderEditing($0, name: "Change \(title)")
            }
            .labelsHidden()
            .controlSize(.small)
            .tint(Theme.bottom)
            Text(text)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .frame(width: 36, alignment: .trailing)
        }
    }
}

struct Swatch: View {
    let backdrop: Backdrop
    let style: MatStyle
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    private var name: String {
        switch backdrop {
        case .gradient(let i): Presets.gradients[i].name
        case .solid(let i): Presets.solids[i].name
        case .custom: "Custom"
        }
    }

    var body: some View {
        var probe = style
        probe.backdrop = backdrop
        let colors = probe.colors
        return Button(action: action) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [colors.top.color, colors.bottom.color], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 40, height: 30)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.black.opacity(0.1)))
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(colors.top.isLight ? .black.opacity(0.7) : .white)
                    }
                }
                .padding(2.5)
                .overlay(RoundedRectangle(cornerRadius: 10.5, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(.clear), lineWidth: 2))
                .scaleEffect(hovering && !selected ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(name)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
        .animation(.snappy(duration: 0.2), value: selected)
    }
}

extension RGB {
    var isLight: Bool { 0.299 * r + 0.587 * g + 0.114 * b > 0.7 }
}

// MARK: - Icon

func appIcon() -> NSBitmapImageRep {
    render(0xFF7A59, 0xD9345F) { ctx in
        // The mat: a vivid card lying on the tile.
        let mat = CGRect(x: 196, y: 214, width: 632, height: 556)
        ctx.saveGState()
        shadow(ctx, y: -18, blur: 40, alpha: 0.32)
        ctx.addPath(roundedRect(mat, 76))
        ctx.setFillColor(rgb(0xFFB25C).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(roundedRect(mat, 76))
        ctx.clip()
        gradient([rgb(0xFFD36E), rgb(0xFF8A4C), rgb(0xF0407A)], from: CGPoint(x: mat.minX, y: mat.maxY),
                 to: CGPoint(x: mat.maxX, y: mat.minY), in: ctx)
        radial([NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0)],
               center: CGPoint(x: mat.minX + 120, y: mat.maxY - 80), radius: 360, in: ctx)
        ctx.restoreGState()
        ctx.addPath(roundedRect(mat.insetBy(dx: 1.5, dy: 1.5), 74.5))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(3)
        ctx.strokePath()

        // The window card resting on it, with a soft long shadow.
        let card = CGRect(x: 290, y: 330, width: 444, height: 320)
        ctx.saveGState()
        shadow(ctx, y: -26, blur: 54, alpha: 0.38)
        ctx.addPath(roundedRect(card, 36))
        ctx.setFillColor(rgb(0xFFFFFF).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(roundedRect(card, 36))
        ctx.clip()
        gradient([rgb(0xFFFFFF), rgb(0xF1EEF2)], from: CGPoint(x: 0, y: card.maxY), to: CGPoint(x: 0, y: card.minY), in: ctx)
        // Title bar.
        ctx.setFillColor(rgb(0xEFEAEE).cgColor)
        ctx.fill(CGRect(x: card.minX, y: card.maxY - 70, width: card.width, height: 70))
        ctx.setFillColor(rgb(0xE0D8DE).cgColor)
        ctx.fill(CGRect(x: card.minX, y: card.maxY - 72, width: card.width, height: 2))
        ctx.restoreGState()
        for (i, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            ctx.setFillColor(rgb(UInt32(hex)).cgColor)
            ctx.fillEllipse(in: CGRect(x: card.minX + 32 + CGFloat(i) * 40, y: card.maxY - 49, width: 26, height: 26))
        }
        // Content: a picture block and two lines.
        ctx.saveGState()
        ctx.addPath(roundedRect(CGRect(x: card.minX + 34, y: card.minY + 36, width: 150, height: 176), 18))
        ctx.clip()
        gradient([rgb(0xFF9A6B), rgb(0xD9345F)], from: CGPoint(x: 0, y: card.minY + 212), to: CGPoint(x: 0, y: card.minY + 36), in: ctx)
        ctx.restoreGState()
        for (i, w) in [196.0, 160.0, 186.0].enumerated() {
            ctx.addPath(roundedRect(CGRect(x: card.minX + 214, y: card.minY + 176 - CGFloat(i) * 62, width: w, height: 26), 13))
            ctx.setFillColor(rgb(i == 0 ? 0x5A4A55 : 0xCDC2CA).cgColor)
            ctx.fillPath()
        }
    }
}
