import AppKit
import Kit
import SwiftUI

enum Theme {
    static let light = Color(red: 0x1F / 255, green: 0xC8 / 255, blue: 0xB0 / 255)
    static let deep = Color(red: 0x0E / 255, green: 0x7C / 255, blue: 0x86 / 255)
    static let accent = Color(red: 0x14 / 255, green: 0xA2 / 255, blue: 0x9C / 255)
    static let gradient = LinearGradient(colors: [light, deep], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct ContentView: View {
    @ObservedObject var model: ShrinkModel
    @Environment(\.undoManager) private var undoManager
    @State private var targeted = false

    var body: some View {
        Group {
            if model.items.isEmpty {
                DropZone(symbol: "photo.stack", title: "Drop images or folders",
                         message: "JPEG, PNG, HEIC, TIFF and WebP. Shrink writes new files and never touches the originals.",
                         button: "Choose Images\u{2026}", tint: Theme.accent, isTargeted: targeted) { model.openImages() }
                    .overlay(alignment: .bottom) {
                        if model.isAdding { ProgressView().controlSize(.small).padding(.bottom, 40) }
                    }
            } else {
                ImageTable(model: model)
                    .safeAreaInset(edge: .bottom, spacing: 0) { SummaryBar(model: model) }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.accent, lineWidth: 3)
                            .opacity(targeted ? 1 : 0)
                            .allowsHitTesting(false)
                    }
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return !urls.isEmpty
        } isTargeted: { targeted = $0 }
        .animation(.snappy(duration: 0.2), value: targeted)
        .inspector(isPresented: $model.showSettings) {
            SettingsPanel(model: model)
                .inspectorColumnWidth(min: 270, ideal: 290, max: 360)
        }
        .toolbar { toolbar }
        .navigationSubtitle(subtitle)
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, value in model.undoManager = value }
    }

    private var subtitle: String {
        let n = model.items.count
        if n == 0 { return "" }
        return "\(n) \(n == 1 ? "image" : "images"), \(Shrinker.bytes(model.totalBytes))"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.openImages() } label: { Label("Add Images", systemImage: "plus") }
                .help("Add images or folders (\u{2318}O)")
            Button { model.reveal(model.selection) } label: { Label("Reveal in Finder", systemImage: "folder") }
                .help("Show the shrunk files in Finder (\u{21E7}\u{2318}R)")
                .disabled(!model.hasOutputs)
            if model.isRunning {
                Button { model.cancel() } label: { Label("Stop", systemImage: "stop.fill") }
                    .help("Stop after the images in progress (\u{2318}.)")
            } else {
                Button { model.shrinkAll() } label: { Label("Shrink All", systemImage: "arrow.down.right.and.arrow.up.left") }
                    .help("Shrink every image in the list (\u{2318}\u{21A9})")
                    .disabled(model.processable.isEmpty)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { withAnimation(.snappy) { model.showSettings.toggle() } } label: {
                Label("Settings", systemImage: "sidebar.trailing")
            }
            .help(model.showSettings ? "Hide settings (\u{2325}\u{2318}I)" : "Show settings (\u{2325}\u{2318}I)")
        }
    }
}

// MARK: - List

struct ImageTable: View {
    @ObservedObject var model: ShrinkModel

    var body: some View {
        Table(model.items, selection: $model.selection) {
            TableColumn("Image") { item in
                HStack(spacing: 10) {
                    Thumbnail(image: item.thumbnail)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Text(kind(item)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.vertical, 3)
                .help(item.url.path)
            }
            .width(min: 180, ideal: 250)
            TableColumn("Dimensions") { item in
                TwoLine(top: item.info.map { Shrinker.dimensions($0.width, $0.height) } ?? "",
                        bottom: item.output.map { Shrinker.dimensions($0.width, $0.height) })
            }
            .width(min: 90, ideal: 110)
            TableColumn("Original") { item in
                Text(item.info.map { Shrinker.bytes($0.bytes) } ?? "").monospacedDigit()
            }
            .width(min: 64, ideal: 74)
            TableColumn("New") { item in
                AccentText(text: item.output.map { Shrinker.bytes($0.bytes) } ?? "")
            }
            .width(min: 64, ideal: 74)
            TableColumn("Saved") { item in StatusCell(item: item) }
                .width(min: 74, ideal: 84)
        }
        .contextMenu(forSelectionType: ImageItem.ID.self) { ids in
            Button("Reveal in Finder") { model.reveal(ids) }
                .disabled(!model.items.contains { ids.contains($0.id) && $0.output != nil })
            Button("Reveal Original in Finder") { model.revealOriginals(ids) }
            Divider()
            Button(ids.count > 1 ? "Remove \(ids.count) Images" : "Remove from List") { model.remove(ids) }
                .disabled(model.isRunning)
        } primaryAction: { ids in
            model.reveal(ids)
        }
    }

    private func kind(_ item: ImageItem) -> String {
        guard let info = item.info else { return item.state == .loading ? "Reading\u{2026}" : "Unreadable" }
        let from = Shrinker.typeName(info.type)
        if let out = item.output { return "\(from) to \(Shrinker.typeName(out.type))" }
        return from
    }
}

struct Thumbnail: View {
    let image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary.opacity(0.5))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .frame(width: 40, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
    }
}

struct TwoLine: View {
    let top: String
    let bottom: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(top).monospacedDigit().foregroundStyle(bottom == nil ? .primary : .secondary)
            if let bottom { AccentText(text: bottom) }
        }
        .lineLimit(1)
    }
}

/// Teal text that turns white on a selected row, where teal on blue would not read.
struct AccentText: View {
    let text: String
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Text(text)
            .monospacedDigit()
            .fontWeight(.medium)
            .foregroundStyle(prominence == .increased ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.deep))
    }
}

struct StatusCell: View {
    let item: ImageItem

    var body: some View {
        Group {
            switch item.state {
            case .loading, .working:
                ProgressView().controlSize(.small)
            case .queued:
                Text("Waiting").foregroundStyle(.secondary)
            case .ready:
                Text("Ready").foregroundStyle(.tertiary)
            case .failed(let message):
                Label("Failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(message)
            case .done:
                if let saved = item.saved, let info = item.info {
                    SavedBadge(percent: Shrinker.percentSaved(original: info.bytes, new: info.bytes - saved))
                }
            }
        }
        .transition(.opacity)
        .animation(.snappy, value: item.state)
    }
}

struct SavedBadge: View {
    let percent: Int

    var body: some View {
        let grew = percent < 0
        Text(grew ? "+\(-percent)%" : "\(percent)%")
            .font(.system(size: 11.5, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(grew ? AnyShapeStyle(Color.orange.gradient) : AnyShapeStyle(Theme.gradient)))
            .help(grew ? "The new file is larger than the original" : "Smaller than the original by \(percent)%")
    }
}

// MARK: - Summary bar

struct SummaryBar: View {
    @ObservedObject var model: ShrinkModel

    var body: some View {
        HStack(spacing: 14) {
            if model.isRunning {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Shrinking \(min(model.completed + 1, model.batchTotal)) of \(model.batchTotal)")
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    ProgressView(value: Double(model.completed), total: Double(max(model.batchTotal, 1)))
                        .tint(Theme.accent)
                        .frame(maxWidth: 260)
                }
                Spacer()
                Button("Stop") { model.cancel() }.controlSize(.large)
            } else {
                summary
                Spacer(minLength: 12)
                if model.hasOutputs {
                    Button("Reveal in Finder") { model.reveal(model.selection) }.controlSize(.large)
                }
                Button { model.shrinkAll() } label: {
                    Label("Shrink All", systemImage: "arrow.down.right.and.arrow.up.left").padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.large)
                .disabled(model.processable.isEmpty)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(minHeight: 64)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .animation(.snappy, value: model.isRunning)
    }

    @ViewBuilder
    private var summary: some View {
        if !model.doneItems.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.gradient))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Saved \(Shrinker.bytes(model.savedBytes))")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                        Text("\(model.savedPercent)% smaller")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.deep)
                    }
                    .monospacedDigit()
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.items.count) \(model.items.count == 1 ? "image" : "images") ready")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(model.settings.summary).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var detail: String {
        let n = model.doneItems.count
        var text = "\(Shrinker.bytes(model.doneOriginalBytes)) down to \(Shrinker.bytes(model.doneNewBytes)) across \(n) \(n == 1 ? "image" : "images")"
        if model.failedCount > 0 { text += ", \(model.failedCount) failed" }
        return text
    }
}

// MARK: - Settings

struct SettingsPanel: View {
    @ObservedObject var model: ShrinkModel

    private var s: Binding<ShrinkSettings> { $model.settings }

    var body: some View {
        Form {
            Section {
                Picker("Format", selection: s.format) {
                    ForEach(OutputFormat.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                LabeledContent("Quality") {
                    HStack(spacing: 8) {
                        Slider(value: s.quality, in: 0.1...1).labelsHidden()
                        Text("\(Int((model.settings.quality * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                            .contentTransition(.numericText())
                    }
                }
                .disabled(model.settings.format == .png)
            } header: { Text("Format") } footer: { Caption(formatNote) }
            Section {
                Picker("Resize", selection: s.resize) {
                    ForEach(ResizeMode.allCases) { Text($0.title).tag($0) }
                }
                switch model.settings.resize {
                case .none:
                    EmptyView()
                case .fit:
                    PixelField(title: "Max width", value: s.maxWidth)
                    PixelField(title: "Max height", value: s.maxHeight)
                case .percent:
                    LabeledContent("Scale") {
                        HStack(spacing: 8) {
                            Slider(value: s.percent, in: 5...100).labelsHidden()
                            Text("\(Int(model.settings.percent.rounded()))%")
                                .monospacedDigit()
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                }
            } header: { Text("Size") } footer: { Caption("Keeps the proportions and never enlarges an image.") }
            Section {
                Toggle("Strip metadata", isOn: s.stripMetadata)
                Picker("Save", selection: s.location) {
                    ForEach(OutputLocation.allCases) { Text($0.title).tag($0) }
                }
                if model.settings.location == .nextToOriginal {
                    LabeledContent("Suffix") {
                        TextField("Suffix", text: s.suffix, prompt: Text("-small"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                    }
                } else {
                    LabeledContent("Folder") {
                        Button(model.settings.folderURL?.lastPathComponent ?? "Choose\u{2026}") { model.chooseOutputFolder() }
                            .help(model.settings.folderPath ?? "Choose where shrunk images go")
                    }
                }
            } header: { Text("Output") } footer: { Caption(outputNote) }
        }
        .formStyle(.grouped)
        .tint(Theme.accent)
        .disabled(model.isRunning)
        .animation(.snappy, value: model.settings.resize)
        .animation(.snappy, value: model.settings.location)
    }

    private var example: String {
        let type = Shrinker.outputType(sourceType: "public.jpeg", hasAlpha: false, format: model.settings.format)
        let ext = Shrinker.fileExtension(for: type, source: URL(fileURLWithPath: "/photo.jpg"))
        let suffix = Shrinker.sanitizedSuffix(model.settings.suffix)
        // Non-breaking hyphens keep the file name on one line.
        return "photo\(suffix).\(ext)".replacingOccurrences(of: "-", with: "\u{2011}")
    }

    private var outputNote: String {
        let metadata = model.settings.stripMetadata ? "Location, camera and date details are removed. " : "Camera, date and location details are kept. "
        if model.settings.location == .nextToOriginal { return metadata + "photo.jpg becomes \(example). Originals are never overwritten." }
        return metadata + "Files keep their names, with a number added if one is taken."
    }

    private var formatNote: String {
        switch model.settings.format {
        case .keep: "Each image keeps its format. WebP becomes JPEG, or PNG when it has transparency."
        case .jpeg: "Smallest for photos. Transparent areas become white."
        case .heic: "About half the size of JPEG at the same quality."
        case .png: "Lossless, so quality does not apply. Best for screenshots and graphics."
        }
    }
}

struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct PixelField: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: $value, format: .number.grouping(.never))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 70)
                    .onChange(of: value) { _, v in if v < 1 { value = 1 } else if v > 100_000 { value = 100_000 } }
                Text("px").foregroundStyle(.secondary)
            }
        }
    }
}
