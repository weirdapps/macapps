import AppKit
import Kit
import SwiftUI
import UniformTypeIdentifiers

enum Theme {
    static let top = Color(red: 0x5B / 255, green: 0x5B / 255, blue: 0xF0 / 255)
    static let bottom = Color(red: 0x2E / 255, green: 0x2A / 255, blue: 0x8F / 255)
    static let gradient = LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let card = Color(nsColor: .controlBackgroundColor)
}

struct ContentView: View {
    @ObservedObject var model: ScrubModel
    @State private var targeted = false

    var body: some View {
        Group {
            if model.photos.isEmpty {
                DropZone(symbol: "photo.badge.checkmark", title: "Drop photos to inspect",
                         message: "Scrub shows the camera, date and place hidden inside each photo, and saves clean copies without them.",
                         button: "Choose Photos\u{2026}", tint: Theme.top, isTargeted: targeted) { model.showImporter = true }
                    .frame(minWidth: 720, minHeight: 460)
            } else {
                NavigationSplitView {
                    Sidebar(model: model)
                        .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
                } detail: {
                    DetailView(model: model)
                        .frame(minWidth: 480)
                }
            }
        }
        .toolbar { toolbar }
        .navigationTitle("Scrub")
        .navigationSubtitle(subtitle)
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { targeted = $0 }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [.image, .folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.add(urls) }
        }
    }

    private var subtitle: String {
        let n = model.photos.count
        guard n > 0 else { return "" }
        let located = model.photos.filter { $0.flags.contains(.location) && $0.result == nil }.count
        return "\(n) \(n == 1 ? "photo" : "photos")" + (located > 0 ? ", \(located) with location" : "")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.showImporter = true } label: { Label("Add Photos", systemImage: "plus") }
                .help("Add photos or a folder of photos")
            Button { model.clean(.location) } label: { Label("Remove Location", systemImage: "location.slash") }
                .help("Save copies of the selected photos without their location")
                .disabled(!model.canClean(.location, all: false))
            Button { model.clean(.all) } label: { Label("Remove All Metadata", systemImage: "eraser") }
                .help("Save copies of the selected photos without any metadata")
                .disabled(!model.canClean(.all, all: false))
            Button { model.revealOutputs() } label: { Label("Reveal Cleaned Copies", systemImage: "folder") }
                .help("Show the cleaned copies in Finder")
                .disabled(model.cleanedOutputs.isEmpty)
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var model: ScrubModel

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.photos) { photo in
                PhotoRow(photo: photo).tag(photo.id)
                    .contextMenu {
                        if let out = photo.result?.output { Button("Reveal Cleaned Copy in Finder") { revealInFinder([out]) } }
                        Button("Show Original in Finder") { revealInFinder([photo.url]) }
                        Divider()
                        Button("Remove from List") { model.remove(model.selection.contains(photo.id) ? model.selection : [photo.id]) }
                    }
            }
        }
        .onDeleteCommand { model.remove(model.selection) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let notice = model.notice {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(notice).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

struct PhotoRow: View {
    let photo: Photo

    var body: some View {
        HStack(spacing: 10) {
            Thumb(image: photo.thumbnail, side: 40, radius: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(photo.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(photo.summary).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 4)
            status
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var status: some View {
        if photo.result != nil {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).help("A cleaned copy was saved and verified")
        } else if photo.error != nil {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(photo.error ?? "")
        } else if photo.flags.contains(.location) {
            Image(systemName: "location.fill").font(.system(size: 11)).foregroundStyle(.red).help("Has a location")
        } else if photo.loading {
            ProgressView().controlSize(.small)
        }
    }
}

struct Thumb: View {
    let image: NSImage?
    let side: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.quaternary.opacity(0.5))
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.black.opacity(0.08)))
    }
}

// MARK: - Detail

struct DetailView: View {
    @ObservedObject var model: ScrubModel

    var body: some View {
        Group {
            let selected = model.selected
            if selected.count == 1, let photo = selected.first {
                PhotoDetail(model: model, photo: photo)
            } else if selected.count > 1 {
                MultiDetail(model: model, photos: selected)
            } else {
                ContentUnavailableView("Select a photo", systemImage: "photo.on.rectangle",
                                       description: Text("Pick a photo in the sidebar to see what it says about you."))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let job = model.job {
                HStack(spacing: 12) {
                    ProgressView(value: Double(job.done), total: Double(max(job.total, 1))).frame(maxWidth: 220)
                    Text("\(job.title), \(min(job.done + 1, job.total)) of \(job.total)")
                        .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                        .contentTransition(.numericText())
                    Spacer()
                    Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
        }
        .animation(.snappy, value: model.job?.done)
    }
}

struct PhotoDetail: View {
    @ObservedObject var model: ScrubModel
    let photo: Photo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                if let result = photo.result { OutcomeBanner(result: result) }
                if let error = photo.error { ErrorBanner(message: error) }
                if let report = photo.report {
                    if report.groups.isEmpty {
                        EmptyMetadata()
                    } else {
                        Columns(groups: report.groups, coordinate: report.coordinate, map: model.maps[photo.id],
                                mapUnavailable: model.mapsUnavailable.contains(photo.id))
                    }
                }
            }
            .padding(22)
        }
        .onAppear { model.requestMap(for: photo) }
        .onChange(of: photo.report?.coordinate) { model.requestMap(for: photo) }
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 20) {
            Preview(image: photo.thumbnail)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(photo.name).font(.system(size: 20, weight: .bold, design: .rounded)).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    if let r = photo.report {
                        Text("\(r.typeName), \(r.pixelWidth) \u{00D7} \(r.pixelHeight), \(Format.bytes(photo.fileSize)), \(r.tagCount) tags")
                            .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if let r = photo.report {
                    PrivacyBadges(flags: r.sortedFlags)
                    Text(photo.result == nil ? Exposure.sentence(r.flags) : "The original still carries this. The cleaned copy does not.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    Button { model.clean(.location) } label: { Label("Remove Location", systemImage: "location.slash.fill") }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy || !photo.flags.contains(.location))
                    Button { model.clean(.all) } label: { Label("Remove All Metadata", systemImage: "eraser.fill") }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.top)
                        .disabled(model.isBusy || photo.flags.isEmpty)
                }
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 196)
    }
}

struct Preview: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.black.opacity(0.08)))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5))
                    .overlay(Image(systemName: "photo").font(.system(size: 30)).foregroundStyle(.tertiary))
            }
        }
        .frame(maxWidth: 262, maxHeight: 196)
    }
}

struct PrivacyBadges: View {
    let flags: [PrivacyFlag]

    var body: some View {
        FlowLayout(spacing: 6) {
            if flags.isEmpty {
                Badge(symbol: "checkmark.shield.fill", title: "No personal metadata", color: .green)
            }
            ForEach(flags, id: \.self) { flag in
                Badge(symbol: flag.symbol, title: flag.title, color: flag.isHigh ? .red : .secondary)
            }
        }
    }
}

struct Badge: View {
    let symbol: String
    let title: String
    let color: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
        }
        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
        .foregroundStyle(color == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color == .secondary ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(color.opacity(0.12))))
    }
}

struct OutcomeBanner: View {
    let result: CleanResult

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 22)).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.mode == .all ? "Clean copy saved and verified" : "Copy without location saved and verified")
                    .font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Reveal in Finder") { revealInFinder([result.output]) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.green.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.green.opacity(0.25)))
    }

    private var detail: String {
        let left = result.report.tagCount
        return result.output.lastPathComponent + ", " + (result.lossless ? "image data copied untouched" : "re-encoded at high quality")
            + ", \(left) technical \(left == 1 ? "tag" : "tags") left"
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.system(size: 12))
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.1)))
    }
}

struct EmptyMetadata: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill").font(.system(size: 26)).foregroundStyle(.green)
            Text("This photo carries no camera, date or location details.").foregroundStyle(.secondary)
            Spacer()
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
    }
}

// MARK: - Metadata cards

struct Columns: View {
    let groups: [MetaGroup]
    let coordinate: Coordinate?
    let map: NSImage?
    let mapUnavailable: Bool

    var body: some View {
        let split = balance()
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 14) { ForEach(split.0) { card($0) } }.frame(maxWidth: .infinity)
            VStack(spacing: 14) { ForEach(split.1) { card($0) } }.frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func card(_ g: MetaGroup) -> some View {
        if g.title == "Location", let coordinate {
            MetaCard(group: g) { LocationMap(coordinate: coordinate, image: map, unavailable: mapUnavailable) }
        } else {
            MetaCard(group: g) { EmptyView() }
        }
    }

    /// Splits the cards into two columns of similar height, keeping their order within each column.
    private func balance() -> ([MetaGroup], [MetaGroup]) {
        var left: [MetaGroup] = [], right: [MetaGroup] = []
        var lh = 0.0, rh = 0.0
        // The map card leads the right column: it is the part people most often do not expect.
        if let i = groups.firstIndex(where: { $0.title == "Location" }), coordinate != nil {
            right.append(groups[i])
            rh = 44 + Double(groups[i].rows.count) * 24 + 150
        }
        for g in groups where !(g.title == "Location" && coordinate != nil) {
            let h = 44 + Double(g.rows.count) * 24
            if lh <= rh { left.append(g); lh += h } else { right.append(g); rh += h }
        }
        return (left, right)
    }
}

struct MetaCard<Accessory: View>: View {
    let group: MetaGroup
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: group.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.gradient)
                    .frame(width: 16)
                Text(group.title).font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
            }
            accessory()
            VStack(spacing: 0) {
                ForEach(Array(group.rows.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { Divider().opacity(0.5) }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(row.label).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if row.sensitive {
                            Image(systemName: "eye.fill").font(.system(size: 9)).foregroundStyle(.red.opacity(0.75))
                                .help("This can identify you or where you were")
                        }
                        Text(row.value).multilineTextAlignment(.trailing).textSelection(.enabled).monospacedDigit()
                    }
                    .font(.system(size: 12))
                    .padding(.vertical, 5)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.07)))
    }
}

struct LocationMap: View {
    let coordinate: Coordinate
    let image: NSImage?
    let unavailable: Bool
    @State private var hovering = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                Pin()
            } else {
                Rectangle().fill(.quaternary.opacity(0.4))
                VStack(spacing: 6) {
                    Image(systemName: unavailable ? "map" : "globe.europe.africa").font(.system(size: 22)).foregroundStyle(.tertiary)
                    if unavailable {
                        Text("Map unavailable offline").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .frame(height: 140)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            Button { openInMaps() } label: {
                Label("Open in Maps", systemImage: "arrow.up.forward.app").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(.regularMaterial))
            .opacity(hovering || image == nil ? 1 : 0.85)
            .padding(8)
        }
        .onHover { hovering = $0 }
    }

    private func openInMaps() {
        let s = String(format: "%.6f,%.6f", coordinate.latitude, coordinate.longitude)
        if let url = URL(string: "maps://?ll=\(s)&q=\(s)") { NSWorkspace.shared.open(url) }
    }
}

struct Pin: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.red.gradient).frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
            Image(systemName: "camera.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
        }
    }
}

// MARK: - Several photos

struct MultiDetail: View {
    @ObservedObject var model: ScrubModel
    let photos: [Photo]

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                ForEach(Array(photos.prefix(3).enumerated().reversed()), id: \.element.id) { i, p in
                    Thumb(image: p.thumbnail, side: 128, radius: 12)
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                        .rotationEffect(.degrees(Double(i) * 7 - 7))
                        .offset(x: CGFloat(i) * 26 - 26)
                }
            }
            .frame(height: 150)
            Text("\(photos.count) photos selected").font(.system(size: 20, weight: .bold, design: .rounded))
            VStack(spacing: 6) {
                ForEach(PrivacyFlag.allCases, id: \.self) { flag in
                    let n = photos.filter { $0.flags.contains(flag) }.count
                    if n > 0 {
                        HStack {
                            Image(systemName: flag.symbol).frame(width: 20)
                                .foregroundStyle(flag.isHigh ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            Text(flag.title).foregroundStyle(flag.isHigh ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                            Spacer()
                            Text("\(n) of \(photos.count)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12.5))
                    }
                }
            }
            .frame(width: 280)
            HStack(spacing: 10) {
                Button { model.clean(.location) } label: { Label("Remove Location", systemImage: "location.slash.fill") }
                    .buttonStyle(.bordered)
                    .disabled(!model.canClean(.location, all: false))
                Button { model.clean(.all) } label: { Label("Remove All Metadata", systemImage: "eraser.fill") }
                    .buttonStyle(.borderedProminent).tint(Theme.top)
                    .disabled(!model.canClean(.all, all: false))
            }
            .controlSize(.large)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage(Prefs.suffix) private var suffix = Prefs.defaultSuffix
    @AppStorage(Prefs.useFolder) private var useFolder = false
    @AppStorage(Prefs.folder) private var folder = ""

    var body: some View {
        Form {
            Section {
                Picker("Save cleaned copies", selection: $useFolder) {
                    Text("Next to the original").tag(false)
                    Text("In a folder").tag(true)
                }
                .pickerStyle(.radioGroup)
                if useFolder {
                    LabeledContent("Folder") {
                        HStack {
                            Text(folder.isEmpty ? "None chosen" : (folder as NSString).abbreviatingWithTildeInPath)
                                .foregroundStyle(folder.isEmpty ? .tertiary : .secondary).lineLimit(1).truncationMode(.middle)
                            Button("Choose\u{2026}") { choose() }
                        }
                    }
                }
                TextField("Name suffix", text: $suffix)
            } footer: {
                Text("Example: IMG_4021\(suffix.trimmingCharacters(in: .whitespaces).isEmpty ? Prefs.defaultSuffix : suffix).HEIC. Originals are never changed.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}

// MARK: - Flow layout

/// Lays out badges left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width { rows.append(Row()) }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
