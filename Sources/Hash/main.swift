import AppKit
import CryptoKit
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
    let model = HashModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "number", accessibilityLabel: "Hash") {
            HashView().environmentObject(self.model)
        }
    }
}

// MARK: - Model

enum Algo: String, CaseIterable, Identifiable {
    case md5 = "MD5", sha1 = "SHA-1", sha256 = "SHA-256", sha384 = "SHA-384", sha512 = "SHA-512"

    var id: String { rawValue }
    var insecure: Bool { self == .md5 || self == .sha1 }
}

/// Feeds the same bytes to every algorithm at once, so a file is read only one time.
struct MultiHasher {
    private var md5 = Insecure.MD5()
    private var sha1 = Insecure.SHA1()
    private var sha256 = SHA256()
    private var sha384 = SHA384()
    private var sha512 = SHA512()

    mutating func update(_ data: Data) {
        md5.update(data: data)
        sha1.update(data: data)
        sha256.update(data: data)
        sha384.update(data: data)
        sha512.update(data: data)
    }

    func finalize() -> [Algo: String] {
        func hex<D: Digest>(_ d: D) -> String { d.map { String(format: "%02x", $0) }.joined() }
        return [.md5: hex(md5.finalize()), .sha1: hex(sha1.finalize()), .sha256: hex(sha256.finalize()),
                .sha384: hex(sha384.finalize()), .sha512: hex(sha512.finalize())]
    }

    static func digests(of text: String) -> [Algo: String] {
        var h = MultiHasher()
        h.update(Data(text.utf8))
        return h.finalize()
    }

    /// Streams the file in 4 MB chunks. `progress` gets the fraction read; return false from it to stop.
    static func digests(of url: URL, progress: (Double) -> Bool) throws -> [Algo: String]? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Double.init) ?? 0
        var h = MultiHasher()
        var read = 0.0
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            h.update(chunk)
            read += Double(chunk.count)
            if !progress(size > 0 ? min(1, read / size) : 0) { return nil }
        }
        return h.finalize()
    }

    /// The algorithm whose digest equals a pasted hash. Ignores case, spaces, colons and a leading "sha256:" style label.
    static func match(_ expected: String, in digests: [Algo: String]) -> Algo? {
        var s = expected.lowercased().filter { !$0.isWhitespace && $0 != ":" }
        if let label = ["sha256", "sha384", "sha512", "sha1", "md5", "sha-256", "sha-384", "sha-512", "sha-1"].first(where: { s.hasPrefix($0) }),
           s.count > label.count, s.dropFirst(label.count).allSatisfy(\.isHexDigit) {
            s.removeFirst(label.count)
        }
        guard !s.isEmpty else { return nil }
        return Algo.allCases.first { digests[$0] == s }
    }
}

@MainActor
final class HashModel: ObservableObject {
    enum Source: Equatable { case text, file(URL) }

    @Published var text = "abc" { didSet { if source == .text { digests = MultiHasher.digests(of: text) } } }
    @Published var expected = ""
    @Published private(set) var source: Source = .text
    @Published private(set) var digests: [Algo: String] = MultiHasher.digests(of: "abc")
    @Published private(set) var progress: Double?
    @Published private(set) var fileError: String?
    @AppStorage("uppercase") var uppercase = false

    private var job: Task<Void, Never>?
    private var generation = 0

    var matched: Algo? { MultiHasher.match(expected, in: digests) }

    func useText() {
        job?.cancel()
        source = .text
        progress = nil
        fileError = nil
        digests = MultiHasher.digests(of: text)
    }

    func hash(file url: URL) {
        job?.cancel()
        generation += 1
        let mine = generation
        source = .file(url)
        digests = [:]
        fileError = nil
        progress = 0
        job = Task.detached(priority: .userInitiated) { [weak self] in
            var lastReport = Date.distantPast
            let result = Result {
                try MultiHasher.digests(of: url) { fraction in
                    if Date().timeIntervalSince(lastReport) > 0.05 {
                        lastReport = Date()
                        Task { @MainActor [weak self] in self?.report(progress: fraction, generation: mine) }
                    }
                    return !Task.isCancelled
                }
            }
            await self?.finish(result, generation: mine)
        }
    }

    private func report(progress fraction: Double, generation mine: Int) {
        if generation == mine, progress != nil { progress = fraction }
    }

    private func finish(_ result: Result<[Algo: String]?, Error>, generation mine: Int) {
        guard generation == mine else { return }
        progress = nil
        switch result {
        case .success(let d?): digests = d
        case .success(nil): break
        case .failure(let e): fileError = e.localizedDescription
        }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { hash(file: url) }
    }

    func display(_ digest: String) -> String { uppercase ? digest.uppercased() : digest }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Views

struct HashView: View {
    @EnvironmentObject var model: HashModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 10) {
                SourcePicker()
                switch model.source {
                case .text: TextInput()
                case .file(let url): FileCard(url: url)
                }
                Results()
                CompareField()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            Divider().opacity(0.5)
            PanelFooter(name: "Hash") {
                Toggle("Uppercase Hex", isOn: $model.uppercase)
                Button("Choose File…") { model.chooseFile() }
            }
        }
        .frame(width: 400)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentGradient, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentTint.opacity(0.12)))
                    .overlay(Label("Drop to hash this file", systemImage: "arrow.down.doc.fill")
                        .font(.system(size: 15, weight: .semibold, design: .rounded)))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { model.hash(file: url) }
            }
            return true
        }
        .animation(.snappy(duration: 0.2), value: dropTargeted)
    }

    private var header: some View {
        HStack {
            Text("Hash").font(.system(size: 17, weight: .bold, design: .rounded))
            Spacer()
            Text("Drop a file anywhere").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct SourcePicker: View {
    @EnvironmentObject var model: HashModel
    @Namespace private var namespace

    private var isText: Bool { model.source == .text }

    var body: some View {
        HStack(spacing: 2) {
            segment("Text", "text.alignleft", selected: isText) { model.useText() }
            segment("File", "doc", selected: !isText) {
                if isText { model.chooseFile() }
            }
        }
        .padding(2.5)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
    }

    private func segment(_ title: String, _ symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { action() }
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(selected ? .white : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background {
                    if selected { Capsule().fill(Color.accentGradient).matchedGeometryEffect(id: "pill", in: namespace) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct TextInput: View {
    @EnvironmentObject var model: HashModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text("\(model.text.utf8.count) bytes of UTF-8").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                PaneButton("doc.on.clipboard", "Paste") { model.text = NSPasteboard.general.string(forType: .string) ?? "" }
                PaneButton("xmark", "Clear") { model.text = "" }
            }
            TextEditor(text: $model.text)
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: 70)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
        }
    }
}

struct FileCard: View {
    @EnvironmentObject var model: HashModel
    let url: URL

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(url.lastPathComponent).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if let progress = model.progress {
                    ProgressView(value: progress).progressViewStyle(.linear).tint(Color.accentTint)
                } else if let error = model.fileError {
                    Text(error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
                } else {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            GlassIconButton("folder", help: "Choose another file") { model.chooseFile() }
        }
        .padding(10)
        .frame(height: 70)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
    }
}

struct Results: View {
    @EnvironmentObject var model: HashModel

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Algo.allCases) { algo in
                DigestRow(algo: algo, digest: model.digests[algo], matched: model.matched == algo)
            }
        }
    }
}

struct DigestRow: View {
    @EnvironmentObject var model: HashModel
    let algo: Algo
    let digest: String?
    let matched: Bool
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Button {
            guard let digest else { return }
            model.copy(model.display(digest))
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { withAnimation { copied = false } }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(algo.rawValue).font(.system(size: 11, weight: .bold, design: .rounded))
                    if algo.insecure {
                        Text("not for security").font(.system(size: 8.5, weight: .medium)).foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 66, alignment: .leading)
                Text(digest.map(model.display) ?? "Hashing…")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(digest == nil ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: copied ? "checkmark.circle.fill" : matched ? "checkmark.seal.fill" : "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundStyle(copied || matched ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .opacity(hovering || copied || matched ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(matched ? AnyShapeStyle(Color.green.opacity(0.16)) : AnyShapeStyle(.quaternary.opacity(hovering ? 0.55 : 0.28))))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.green.opacity(matched ? 0.6 : 0), lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(digest.map { "Copy \(algo.rawValue): \($0)" } ?? "")
        .onHover { hovering = $0 }
        .animation(.snappy, value: matched)
    }
}

struct CompareField: View {
    @EnvironmentObject var model: HashModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "equal.circle").foregroundStyle(.secondary)
            TextField("Paste an expected hash to compare", text: $model.expected)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
            if !model.expected.isEmpty {
                if let algo = model.matched {
                    Label("\(algo.rawValue) matches", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if !model.digests.isEmpty {
                    Label("No match", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
            } else {
                Button { model.expected = NSPasteboard.general.string(forType: .string) ?? "" } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Paste from clipboard")
            }
        }
        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
        .animation(.snappy, value: model.matched)
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
    static let accentTint = Color(red: 0.4, green: 0.68, blue: 0.12)
    static let accentGradient = LinearGradient(colors: [Color(red: 0.62, green: 0.86, blue: 0.27), Color(red: 0.3, green: 0.55, blue: 0.08)],
                                               startPoint: .top, endPoint: .bottom)
}

// MARK: - Icon

//: a bold hash sign stamped on a fingerprint of concentric arcs

func appIcon() -> NSBitmapImageRep {
    render(0xBEF264, 0x4D7C0F) { ctx in
        // Fingerprint ridges, faint behind the mark.
        ctx.setLineCap(.round)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        ctx.setLineWidth(18)
        let c = CGPoint(x: 512, y: 470)
        for (n, r) in stride(from: 90, through: 390, by: 50).enumerated() {
            let gap = 0.35 + Double(n % 3) * 0.25
            ctx.addArc(center: c, radius: CGFloat(r), startAngle: .pi * (0.15 + gap * 0.2), endAngle: .pi * (0.95 + gap * 0.3), clockwise: false)
            ctx.strokePath()
            ctx.addArc(center: c, radius: CGFloat(r), startAngle: .pi * (1.2 + gap * 0.2), endAngle: .pi * (1.85 + gap * 0.1), clockwise: false)
            ctx.strokePath()
        }
        // The hash sign, slanted, as one shadowed white layer.
        ctx.saveGState()
        shadow(ctx, y: -16, blur: 32, alpha: 0.3)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(74)
        ctx.move(to: CGPoint(x: 450, y: 770)); ctx.addLine(to: CGPoint(x: 390, y: 254))
        ctx.move(to: CGPoint(x: 654, y: 770)); ctx.addLine(to: CGPoint(x: 594, y: 254))
        ctx.move(to: CGPoint(x: 270, y: 622)); ctx.addLine(to: CGPoint(x: 774, y: 622))
        ctx.move(to: CGPoint(x: 250, y: 402)); ctx.addLine(to: CGPoint(x: 754, y: 402))
        ctx.strokePath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        // A check badge in the lower right: the hashes match.
        let b = CGPoint(x: 760, y: 270)
        ctx.saveGState()
        shadow(ctx, y: -8, blur: 18, alpha: 0.3)
        ctx.setFillColor(rgb(0x1A2E05).cgColor)
        ctx.fillEllipse(in: CGRect(x: b.x - 92, y: b.y - 92, width: 184, height: 184))
        ctx.restoreGState()
        ctx.setStrokeColor(rgb(0xBEF264).cgColor)
        ctx.setLineWidth(30)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: b.x - 44, y: b.y + 2)); ctx.addLine(to: CGPoint(x: b.x - 10, y: b.y - 32)); ctx.addLine(to: CGPoint(x: b.x + 46, y: b.y + 34))
        ctx.strokePath()
    }
}
