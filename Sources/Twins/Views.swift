import AppKit
import Kit
import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

enum Theme {
    static let top = Color(red: 0x2B / 255, green: 0xD9 / 255, blue: 0xC6 / 255)
    static let bottom = Color(red: 0x0B / 255, green: 0x8F / 255, blue: 0x9C / 255)
    static let accent = Color(red: 0x12 / 255, green: 0xA8 / 255, blue: 0xB0 / 255)
    static let gradient = LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
}

// MARK: - Root

struct ContentView: View {
    @ObservedObject var model: TwinsModel
    @Environment(\.undoManager) private var undoManager
    @State private var targeted = false

    var body: some View {
        Group {
            switch model.stage {
            case .idle: SetupView(model: model, targeted: targeted)
            case .scanning: ScanningView(model: model)
            case .results:
                if model.groups.isEmpty { NoDuplicatesView(model: model) } else { ResultsView(model: model) }
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .tint(Theme.accent)
        .toolbar { toolbar }
        .dropDestination(for: URL.self) { urls, _ in model.drop(urls) } isTargeted: { targeted = $0 }
        .confirmationDialog(trashTitle, isPresented: $model.confirmingTrash) {
            Button("Move to Trash", role: .destructive) { model.trashMarked() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They take up \(Fmt.bytes(model.markedBytes)). One copy of every file stays where it is, and you can undo with ⌘Z.")
        }
        .alert("Some files were not moved", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.problem ?? "")
        }
        .quickLookPreview($model.quickLook)
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, value in model.undoManager = value }
    }

    private var trashTitle: String { "Move \(Fmt.files(model.marked.count)) to the Trash?" }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.chooseFolders(adding: model.stage == .results) } label: {
                Label("Add Folder", systemImage: "folder.badge.plus")
            }
            .help("Choose folders to scan (⌘O)")
            .disabled(model.isScanning)

            if model.isScanning {
                Button { model.cancelScan() } label: { Label("Stop", systemImage: "stop.fill") }
                    .help("Stop scanning (⌘.)")
            } else {
                Button { model.scan() } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                    .help("Scan the same folders again (⌘R)")
                    .disabled(model.roots.isEmpty)
            }

            Menu {
                ForEach(KeepRule.allCases) { rule in
                    Button { model.apply(rule: rule) } label: { Label(rule.title, systemImage: rule.symbol) }
                }
                Divider()
                Button("Deselect All") { model.deselectAll() }
            } label: {
                Label("Auto Select", systemImage: "wand.and.stars")
            }
            .help("Select every copy except the one to keep")
            .disabled(model.groups.isEmpty || model.isScanning)

            Button { model.requestTrash() } label: { Label("Move to Trash", systemImage: "trash") }
                .help("Move the selected copies to the Trash (⌘⌫)")
                .disabled(model.marked.isEmpty || model.isScanning)
        }
    }
}

// MARK: - Setup

struct SetupView: View {
    @ObservedObject var model: TwinsModel
    let targeted: Bool

    var body: some View {
        VStack(spacing: 0) {
            DropZone(symbol: "doc.on.doc", title: "Find duplicate files",
                     message: "Drop folders here, or choose them. Twins compares sizes, then contents, and moves the extra copies you pick to the Trash.",
                     button: "Choose Folders…", tint: Theme.accent, isTargeted: targeted) { model.chooseFolders() }
            OptionsBar(options: $model.options)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
    }
}

struct OptionsBar: View {
    @Binding var options: ScanOptions

    var body: some View {
        HStack(spacing: 22) {
            Toggle("Skip hidden files", isOn: $options.skipHidden)
            Toggle("Skip inside packages", isOn: $options.skipPackages)
                .help("Leave the contents of apps, libraries and bundles alone")
            Spacer()
            Picker("Minimum size", selection: $options.minimumSize) {
                ForEach(ScanOptions.sizes, id: \.0) { Text($0.1).tag($0.0) }
            }
            .fixedSize()
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 12.5))
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.35)))
    }
}

// MARK: - Scanning

struct ScanningView: View {
    @ObservedObject var model: TwinsModel
    @State private var spin = false

    var body: some View {
        let p = model.progress
        VStack(spacing: 26) {
            ZStack {
                Circle().stroke(.quaternary.opacity(0.6), lineWidth: 11)
                if let f = p.fraction {
                    Circle().trim(from: 0, to: max(0.01, f))
                        .stroke(Theme.gradient, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.snappy, value: f)
                    Text("\(Int((f * 100).rounded(.down)))%")
                        .font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                } else {
                    Circle().trim(from: 0, to: 0.22)
                        .stroke(Theme.gradient, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                        .rotationEffect(.degrees(spin ? 270 : -90))
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
                        .onAppear { spin = true }
                    Image(systemName: "doc.on.doc").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.gradient)
                }
            }
            .frame(width: 150, height: 150)

            HStack(spacing: 18) {
                ForEach(ScanPhase.allCases, id: \.self) { phase in
                    HStack(spacing: 6) {
                        Image(systemName: phase.rawValue < p.phase.rawValue ? "checkmark.circle.fill"
                            : phase == p.phase ? "circle.dotted.circle" : "circle")
                            .foregroundStyle(phase.rawValue <= p.phase.rawValue ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                        Text(phase.title).foregroundStyle(phase == p.phase ? .primary : .secondary)
                    }
                    .font(.system(size: 12.5, weight: phase == p.phase ? .semibold : .regular))
                }
            }

            VStack(spacing: 5) {
                Text(detail(p)).font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Text(p.current.isEmpty ? " " : p.current)
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 420)
            }

            Button("Stop") { model.cancelScan() }.controlSize(.large).keyboardShortcut(.cancelAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detail(_ p: ScanProgress) -> String {
        switch p.phase {
        case .finding: "\(Fmt.files(p.done)) found in \(model.rootNames)"
        case .sizing: "Looking for files of the same size among \(Fmt.files(p.done))"
        case .quick: "Checked \(Fmt.count(p.done)) of \(Fmt.files(p.total))"
        case .full: "\(Fmt.bytes(p.bytesDone)) of \(Fmt.bytes(p.bytesTotal)) hashed"
        }
    }
}

// MARK: - Nothing found

struct NoDuplicatesView: View {
    @ObservedObject var model: TwinsModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: model.freed > 0 ? "sparkles" : "checkmark.seal")
                .font(.system(size: 50, weight: .light)).foregroundStyle(Theme.gradient)
            Text(model.freed > 0 ? "All tidy" : "No duplicates").font(.system(size: 20, weight: .semibold, design: .rounded))
            Text(model.freed > 0
                ? "You freed \(Fmt.bytes(model.freed)). Every file in \(model.rootNames) is now one of a kind."
                : "\(Fmt.files(model.filesScanned)) in \(model.rootNames) are all one of a kind.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            HStack {
                Button("Scan Another Folder…") { model.chooseFolders() }
                Button("Scan Again") { model.scan() }
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Results

struct ResultsView: View {
    @ObservedObject var model: TwinsModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                SummaryCard(model: model).padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
                List(selection: $model.selection) {
                    ForEach(model.visibleGroups) { group in
                        GroupRow(group: group, marked: model.markedCount(in: group)).tag(group.id)
                    }
                }
                .listStyle(.sidebar)
                .overlay {
                    if model.visibleGroups.isEmpty {
                        ContentUnavailableView.search(text: model.search)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 270, ideal: 310, max: 420)
        } detail: {
            VStack(spacing: 0) {
                if let group = model.selectedGroup {
                    GroupDetail(model: model, group: group)
                } else {
                    ContentUnavailableView("Select a group", systemImage: "doc.on.doc",
                                           description: Text("Pick a set of identical files on the left to see every copy."))
                        .frame(maxHeight: .infinity)
                }
                Divider()
                ActionBar(model: model)
            }
        }
        .searchable(text: $model.search, placement: .sidebar, prompt: "Filter by name or folder")
    }
}

struct SummaryCard: View {
    @ObservedObject var model: TwinsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Wasted space").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Text(Fmt.bytes(model.totalWasted))
                .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(Theme.gradient)
                .contentTransition(.numericText())
            Text("\(Fmt.count(model.groups.count)) groups, \(Fmt.files(model.duplicateFiles))")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.primary.opacity(0.75))
            Text(model.freed > 0 ? "\(Fmt.bytes(model.freed)) freed so far"
                : "\(Fmt.files(model.filesScanned)) scanned in \(Fmt.seconds(model.duration))")
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Theme.top.opacity(0.16), Theme.bottom.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent.opacity(0.18)))
        }
    }
}

struct GroupRow: View {
    let group: DuplicateGroup
    let marked: Int

    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(url: group.files[0].url, side: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text("\(Fmt.copies(group.files.count)), \(Fmt.bytes(group.size)) each")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.bytes(group.wasted)).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                if marked > 0 {
                    Label("\(marked)", systemImage: "trash").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .labelStyle(TightLabel())
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon; configuration.title }
    }
}

// MARK: - Group detail

struct GroupDetail: View {
    @ObservedObject var model: TwinsModel
    let group: DuplicateGroup

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 20) {
                    Thumbnail(url: group.files[0].url, side: 140)
                        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                        .onTapGesture(count: 2) { model.quickLook = group.files[0].url }
                        .help("Double-click to Quick Look")
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.name).font(.system(size: 21, weight: .semibold, design: .rounded))
                            .lineLimit(2).truncationMode(.middle)
                        Text(kind).font(.system(size: 12.5)).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Stat(title: "Copies", value: "\(group.files.count)", highlight: false)
                            Stat(title: "Each", value: Fmt.bytes(group.size), highlight: false)
                            Stat(title: "Wasted", value: Fmt.bytes(group.wasted), highlight: true)
                        }
                        Text("SHA-256 \(group.id.prefix(24))…")
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Copies").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Menu("Keep") {
                            ForEach(KeepRule.allCases) { rule in
                                Button(rule.title) {
                                    model.keepOnly(Scanner.keeper(of: group, rule: rule), in: group)
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .font(.system(size: 12))
                        .help("Choose which copy of this file to keep")
                    }
                    VStack(spacing: 6) {
                        ForEach(group.files) { file in
                            FileRow(model: model, group: group, file: file, isMarked: model.marked.contains(file.id))
                        }
                    }
                    Label("Identical byte for byte, checked with SHA-256. Moving a copy to the Trash can be undone.",
                          systemImage: "checkmark.seal")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
            }
            .padding(24)
        }
    }

    private var kind: String {
        let type = UTType(filenameExtension: group.files[0].url.pathExtension)
        return type?.localizedDescription?.capitalizedFirst ?? "Document"
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

struct Stat: View {
    let title: String
    let value: String
    let highlight: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(highlight ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(highlight ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(highlight ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(.quaternary.opacity(0.45)))
        }
    }
}

struct FileRow: View {
    @ObservedObject var model: TwinsModel
    let group: DuplicateGroup
    let file: FileItem
    let isMarked: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { isMarked }, set: { _ in model.toggle(file, in: group) }))
                .toggleStyle(.checkbox).labelsHidden()
                .help(isMarked ? "This copy goes to the Trash" : "Select this copy for the Trash")
            Thumbnail(url: file.url, side: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(file.folder).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Text("Modified \(file.modified.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            if hovering {
                HStack(spacing: 2) {
                    GlassIconButton("eye", help: "Quick Look") { model.quickLook = file.url }
                    GlassIconButton("arrow.right.circle", help: "Show in Finder") { revealInFinder([file.url]) }
                }
                .transition(.opacity)
            }
            Badge(keep: !isMarked)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isMarked ? AnyShapeStyle(Color.red.opacity(hovering ? 0.10 : 0.06))
                    : AnyShapeStyle(.quaternary.opacity(hovering ? 0.55 : 0.3)))
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.18), value: hovering)
        .animation(.snappy(duration: 0.2), value: isMarked)
        .contextMenu {
            Button("Quick Look") { model.quickLook = file.url }
            Button("Show in Finder") { revealInFinder([file.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.url.path, forType: .string)
            }
            Divider()
            Button("Keep Only This Copy") { model.keepOnly(file, in: group) }
        }
    }
}

struct Badge: View {
    let keep: Bool

    var body: some View {
        Text(keep ? "Keep" : "Trash")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(keep ? AnyShapeStyle(.white) : AnyShapeStyle(Color.red))
            .frame(width: 52)
            .padding(.vertical, 3)
            .background {
                Capsule().fill(keep ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.red.opacity(0.12)))
            }
    }
}

struct ActionBar: View {
    @ObservedObject var model: TwinsModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.marked.isEmpty ? "Nothing selected" : "\(Fmt.files(model.marked.count)) selected")
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .contentTransition(.numericText())
                Text(model.marked.isEmpty ? "Use Auto Select or tick the copies to remove."
                    : "\(Fmt.bytes(model.markedBytes)) to free, one copy of each file stays")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Picker("Keep", selection: Binding(get: { model.rule }, set: { model.apply(rule: $0) })) {
                ForEach(KeepRule.allCases) { Text($0.title.replacingOccurrences(of: "Keep ", with: "")).tag($0) }
            }
            .fixedSize()
            .help("Which copy Auto Select keeps")
            Button { model.requestTrash() } label: {
                Label("Move to Trash", systemImage: "trash").padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .disabled(model.marked.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.bar)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var model: TwinsModel

    var body: some View {
        Form {
            Section("Scanning") {
                Toggle("Skip hidden files", isOn: $model.options.skipHidden)
                Toggle("Skip the inside of packages", isOn: $model.options.skipPackages)
                Picker("Minimum file size", selection: $model.options.minimumSize) {
                    ForEach(ScanOptions.sizes, id: \.0) { Text($0.1).tag($0.0) }
                }
            }
            Section("Auto select") {
                Picker("Copy to keep", selection: $model.rule) {
                    ForEach(KeepRule.allCases) { Text($0.title.replacingOccurrences(of: "Keep ", with: "")).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Thumbnails

struct Thumbnail: View {
    let url: URL
    let side: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if Desktop.isSnapshot {
                DemoArt(url: url)
            } else if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: side, height: side)
        .task(id: url) {
            guard !Desktop.isSnapshot else { return }
            image = await ThumbnailCache.shared.image(for: url, side: side)
        }
    }
}

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(for url: URL, side: CGFloat) async -> NSImage? {
        let key = "\(url.path)@\(Int(side))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: scale,
                                                   representationTypes: .all)
        let cg: CGImage? = await withCheckedContinuation { done in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                done.resume(returning: rep?.cgImage)
            }
        }
        guard let cg else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Stand-in thumbnails for the website snapshot, which must not touch real files: little landscapes for photos, type icons otherwise.
struct DemoArt: View {
    let url: URL

    var body: some View {
        let ext = url.pathExtension.lowercased()
        if ["heic", "jpg", "jpeg", "png"].contains(ext) {
            let seed = Double(url.lastPathComponent.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 997 }) / 997
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    LinearGradient(colors: [Color(hue: 0.55 + seed * 0.1, saturation: 0.55, brightness: 0.95),
                                            Color(hue: 0.08 + seed * 0.05, saturation: 0.45, brightness: 1)],
                                   startPoint: .top, endPoint: .bottom)
                    Circle().fill(Color(hue: 0.12, saturation: 0.5, brightness: 1)).frame(width: w * 0.22)
                        .position(x: w * (0.3 + seed * 0.4), y: h * 0.36)
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h * 0.78))
                        p.addLine(to: CGPoint(x: w * 0.32, y: h * 0.5))
                        p.addLine(to: CGPoint(x: w * 0.55, y: h * 0.7))
                        p.addLine(to: CGPoint(x: w * 0.76, y: h * 0.45))
                        p.addLine(to: CGPoint(x: w, y: h * 0.68))
                        p.addLine(to: CGPoint(x: w, y: h))
                        p.addLine(to: CGPoint(x: 0, y: h))
                    }
                    .fill(Color(hue: 0.5 + seed * 0.08, saturation: 0.6, brightness: 0.45))
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.white, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data))
                .resizable().aspectRatio(contentMode: .fit)
        }
    }
}
