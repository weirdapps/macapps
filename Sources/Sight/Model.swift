import AppKit
import Kit
import SwiftUI
import UniformTypeIdentifiers

enum Layout: String, CaseIterable, Identifiable {
    case single, split, grid
    var id: String { rawValue }

    var title: String {
        switch self {
        case .single: "Single"
        case .split: "Split"
        case .grid: "Grid"
        }
    }

    var symbol: String {
        switch self {
        case .single: "rectangle"
        case .split: "rectangle.split.2x1"
        case .grid: "square.grid.2x2"
        }
    }
}

/// Which render of each simulation is the latest one asked for. A newer request for a mode supersedes
/// older ones for that mode only, so changing the severity never cancels the dichromacy renders of a new image.
struct RenderTokens {
    private var latest: [Simulation: Int] = [:]
    private var counter = 0

    mutating func issue(_ modes: [Simulation]) -> Int {
        counter += 1
        for mode in modes { latest[mode] = counter }
        return counter
    }

    func isCurrent(_ mode: Simulation, _ token: Int) -> Bool { latest[mode] == token }
}

/// The view settings Sight remembers between launches.
enum Prefs {
    static let layoutKey = "layout", modeKey = "mode", severityKey = "severity"

    static func layout(_ d: UserDefaults) -> Layout { d.string(forKey: layoutKey).flatMap(Layout.init(rawValue:)) ?? .split }
    static func mode(_ d: UserDefaults) -> Simulation { d.string(forKey: modeKey).flatMap(Simulation.init(rawValue:)) ?? .deuteranopia }
    static func severity(_ d: UserDefaults) -> Double {
        let v = d.double(forKey: severityKey)
        return v.isFinite && v >= 0.1 && v <= 1 ? v : 0.6
    }
}

/// The suggested export file name: the image, the simulation and, for anomalous modes, its severity.
func exportFileName(_ name: String, _ mode: Simulation, severity: Double) -> String {
    let base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    let detail = mode.isAnomalous ? "\(mode.name) \(Int((severity * 100).rounded()))%" : mode.name
    return "\(base.isEmpty ? "Image" : base) (\(detail)).png"
}

/// A CGImage that crosses into background tasks; CGImage is immutable.
struct ImageBox: @unchecked Sendable { let image: CGImage }

@MainActor
final class SightModel: ObservableObject {
    /// The image at preview size, and each simulation of it.
    @Published private(set) var original: CGImage?
    @Published private(set) var previews: [Simulation: CGImage] = [:]
    @Published private(set) var name = ""
    @Published private(set) var pixelSize = CGSize.zero
    @Published private(set) var busy = false
    @Published private(set) var saved: URL?
    @Published var mode: Simulation { didSet { remember(mode.rawValue, Prefs.modeKey) } }
    @Published var layout: Layout { didSet { remember(layout.rawValue, Prefs.layoutKey) } }
    @Published var split: CGFloat = 0.5
    @Published var severity: Double {
        didSet {
            guard severity != oldValue else { return }
            remember(severity, Prefs.severityKey)
            renderPreviews(Simulation.allCases.filter(\.isAnomalous))
        }
    }

    private var full: CGImage?
    private var folder: URL?
    private var preview: Bitmap?
    private var tokens = RenderTokens()
    /// Export and copy can overlap; the spinner shows while any of them runs.
    private var jobs = 0 { didSet { busy = jobs > 0 } }

    init() {
        // The snapshot shows fixed demo settings and never reads the user's own.
        let d = UserDefaults.standard
        mode = Desktop.isSnapshot ? .deuteranopia : Prefs.mode(d)
        layout = Desktop.isSnapshot ? .split : Prefs.layout(d)
        severity = Desktop.isSnapshot ? 0.6 : Prefs.severity(d)
    }

    private func remember(_ value: Any, _ key: String) {
        if !Desktop.isSnapshot { UserDefaults.standard.set(value, forKey: key) }
    }

    static let previewSide = 1600

    var hasImage: Bool { original != nil }

    // MARK: Loading

    func load(_ url: URL) {
        Task {
            let box = await Task.detached { ImageFile.load(url).map(ImageBox.init) }.value
            guard let box else { return fail("\(url.lastPathComponent) is not an image Sight can read.") }
            folder = url.deletingLastPathComponent()
            set(box.image, name: url.deletingPathExtension().lastPathComponent)
        }
    }

    func load(data: Data, name: String = "Pasted image") {
        guard let image = ImageFile.load(data: data) else { return fail("That is not an image Sight can read.") }
        folder = nil
        set(image, name: name)
    }

    func loadSample() {
        folder = nil
        set(Demo.image(), name: "Dashboard")
    }

    /// Takes a new image: makes the preview copy and renders every simulation of it.
    func set(_ image: CGImage, name: String, synchronously: Bool = false) {
        guard image.width > 0, image.height > 0, let bitmap = Bitmap(image, maxSide: Self.previewSide) else {
            return fail("Sight could not read that image.")
        }
        full = image
        self.name = name
        pixelSize = CGSize(width: image.width, height: image.height)
        saved = nil
        preview = bitmap
        original = bitmap.cgImage
        previews = [:]
        if synchronously {
            _ = tokens.issue(Simulation.allCases)
            for mode in Simulation.allCases {
                previews[mode] = bitmap.simulated(mode.matrix(severity: severity)).cgImage
            }
        } else {
            renderPreviews(Simulation.allCases)
        }
    }

    private func renderPreviews(_ modes: [Simulation]) {
        guard let preview else { return }
        let token = tokens.issue(modes), severity = severity
        // The current mode first, so the visible image updates as soon as possible.
        let ordered = modes.filter { $0 == mode } + modes.filter { $0 != mode }
        Task {
            for mode in ordered where tokens.isCurrent(mode, token) {
                let matrix = mode.matrix(severity: severity)
                let result = await Task.detached(priority: .userInitiated) { preview.simulated(matrix) }.value
                guard tokens.isCurrent(mode, token) else { continue }
                previews[mode] = result.cgImage
            }
        }
    }

    // MARK: Open, paste, drop

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose an image or a screenshot of a design"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self.load(url) }
        }
    }

    func paste() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true,
                                               .urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL],
           let url = urls.first {
            return load(url)
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pb.data(forType: type) { return load(data: data) }
        }
        if let image = NSImage(pasteboard: pb), let data = image.tiffRepresentation { return load(data: data) }
        NSSound.beep()
    }

    func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                guard let url = (object as? NSURL) as URL? else { return }
                Task { @MainActor in self.load(url) }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { return }
                Task { @MainActor in self.load(data: data, name: "Dropped image") }
            }
            return true
        }
        return false
    }

    // MARK: Export, copy

    var exportName: String { exportFileName(name, mode, severity: severity) }

    /// The current simulation at full resolution, made off the main thread.
    private func fullSimulation() async -> ImageBox? {
        guard let full else { return nil }
        let matrix = mode.matrix(severity: severity), box = ImageBox(image: full)
        jobs += 1
        defer { jobs -= 1 }
        return await Task.detached(priority: .userInitiated) {
            Bitmap(box.image)?.simulated(matrix).cgImage.map(ImageBox.init)
        }.value
    }

    func export() {
        guard hasImage else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = exportName
        panel.message = "Export the image as seen with \(mode.name.lowercased())"
        if let folder { panel.directoryURL = folder }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self.write(to: url) }
        }
    }

    func write(to url: URL) async {
        guard let box = await fullSimulation() else { return }
        let ok = await Task.detached { ImageFile.writePNG(box.image, to: url) }.value
        guard ok else { return fail("Sight could not write \(url.lastPathComponent).") }
        withAnimation(.snappy) { saved = url }
        let shown = url
        Task {
            try? await Task.sleep(for: .seconds(8))
            if saved == shown { withAnimation(.snappy) { saved = nil } }
        }
    }

    func dismissSaved() { withAnimation(.snappy) { saved = nil } }

    func copy() {
        guard hasImage else { return }
        Task {
            guard let box = await fullSimulation() else { return }
            let image = NSImage(cgImage: box.image, size: NSSize(width: box.image.width, height: box.image.height))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }
    }

    // MARK: Navigation

    func step(_ delta: Int) { withAnimation(.snappy) { mode = mode.next(by: delta) } }

    func nudgeSeverity(_ delta: Double) {
        severity = (min(max(severity + delta, 0.1), 1) * 10).rounded() / 10
    }

    private func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Cannot open image"
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: Demo

    static var demo: SightModel {
        let model = SightModel()
        model.set(Demo.image(), name: "Dashboard", synchronously: true)
        model.mode = .deuteranopia
        model.layout = .split
        model.split = 0.5
        return model
    }
}
