import AppKit
import Kit
import SwiftUI

// MARK: - Sheets

struct Sheet: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var modified = Date()

    /// The first line with text, without its `#`.
    var title: String {
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: CharacterSet(charactersIn: "# \t"))
            if !t.isEmpty { return String(t.prefix(60)) }
        }
        return "Untitled"
    }

    /// The last result on the sheet, for the sidebar.
    var lastResult: String? {
        Engine.evaluate(text).last(where: { $0.value != nil })?.display
    }

    /// The sheet as plain text with every result after an `=`, for export and Copy Sheet with Results.
    var textWithResults: String {
        let lines = text.components(separatedBy: "\n")
        let results = Engine.evaluate(text)
        let width = min(48, lines.map(\.count).max() ?? 0)
        return zip(lines, results).map { line, result in
            guard let display = result.display else { return line }
            let pad = String(repeating: " ", count: max(1, width - line.count + 2))
            return line + pad + "= " + display
        }.joined(separator: "\n")
    }
}

struct Flash: Equatable {
    var text: String
    var url: URL?
}

@MainActor
final class FigureModel: ObservableObject {
    @Published var sheets: [Sheet] { didSet { scheduleSave() } }
    @Published var selection: Sheet.ID?
    @Published var flash: Flash?
    @Published var showReference = false
    @Published var pendingDelete: Sheet.ID?

    private let persists: Bool
    private var saveTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?

    static let storeFile = "sheets.json"

    init() {
        persists = !Desktop.isSnapshot
        let saved = persists ? Storage.load([Sheet].self, app: "Figure", file: Self.storeFile) : nil
        sheets = saved?.isEmpty == false ? saved! : [Sheet(text: Demo.welcome)]
        selection = sheets.first?.id
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    private init(demo: [Sheet]) {
        persists = false
        sheets = demo
        selection = demo.first?.id
    }

    static var demo: FigureModel { FigureModel(demo: Demo.sheets) }

    var current: Sheet? { sheets.first { $0.id == selection } }

    func binding(for id: Sheet.ID) -> Binding<String> {
        Binding(
            get: { self.sheets.first { $0.id == id }?.text ?? "" },
            set: { text in
                guard let i = self.sheets.firstIndex(where: { $0.id == id }), self.sheets[i].text != text else { return }
                self.sheets[i].text = text
                self.sheets[i].modified = Date()
            })
    }

    // MARK: Actions

    func newSheet() {
        let sheet = Sheet(text: "")
        sheets.insert(sheet, at: 0)
        selection = sheet.id
    }

    func duplicate() {
        guard let s = current, let i = sheets.firstIndex(of: s) else { return }
        let copy = Sheet(text: s.text)
        sheets.insert(copy, at: i + 1)
        selection = copy.id
    }

    /// Asks first unless the sheet is empty.
    func requestDelete(_ id: Sheet.ID? = nil) {
        guard let id = id ?? selection, let sheet = sheets.first(where: { $0.id == id }) else { return }
        if sheet.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { delete(id) } else { pendingDelete = id }
    }

    func delete(_ id: Sheet.ID) {
        guard let i = sheets.firstIndex(where: { $0.id == id }) else { return }
        sheets.remove(at: i)
        if sheets.isEmpty { sheets = [Sheet(text: "")] }
        if selection == id || current == nil { selection = sheets[min(i, sheets.count - 1)].id }
        pendingDelete = nil
    }

    func copy(_ text: String, label: String? = nil) {
        if !Desktop.isSnapshot {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        show(Flash(text: label ?? "Copied \(text)"))
    }

    func copyLastResult() {
        guard let r = current?.lastResult else { NSSound.beep(); return }
        copy(r)
    }

    func copyWithResults() {
        guard let s = current else { return }
        copy(s.textWithResults, label: "Copied the sheet with its results")
    }

    func export() {
        guard let s = current else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = s.title.replacingOccurrences(of: "/", with: "-") + ".txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try s.textWithResults.write(to: url, atomically: true, encoding: .utf8)
            show(Flash(text: "Exported \(url.lastPathComponent)", url: url))
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func show(_ f: Flash) {
        withAnimation(.snappy) { flash = f }
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(f.url == nil ? 1.8 : 5))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { self?.flash = nil }
        }
    }

    // MARK: Persistence

    private func scheduleSave() {
        guard persists else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard persists else { return }
        Storage.save(sheets, app: "Figure", file: Self.storeFile)
    }
}

// MARK: - Demo content

enum Demo {
    static let welcome = """
    # Welcome to Figure
    Type on the left, results appear on the right.
    Click a result to copy it.

    price = $1,250
    discount = 15%
    price - discount
    tip: 20% of $86

    rent = 950
    utilities = 120
    rent + utilities
    rent * 12

    # Units and functions
    run: 10 km in mi
    oven: 200 C in F
    3 h + 45 min
    sqrt(144) + 2^3

    # Running total
    coffee: $4.50
    lunch: $12
    taxi: $18.20
    total
    """

    static let lisbon = """
    # Weekend in Lisbon
    flights = $420 × 2
    hotel = $135 × 4
    meals: $45 × 2 × 4
    tram pass: $8.50 × 2
    total
    per person: prev / 2

    # On the ground
    walk to Belém: 7.2 km in mi
    afternoon: 26 C in F
    tip: 18% of $86
    tram ride: 2 h + 35 min
    luggage: 23 kg in lb
    budget = $2,400
    left over: budget - flights - hotel
    """

    static let sheets: [Sheet] = {
        let base = Date(timeIntervalSince1970: 1_793_000_000)
        return [
            Sheet(text: lisbon, modified: base),
            Sheet(text: "# Kitchen renovation\ncabinets = €4,800\ncountertop = €1,350\nlabour = 32 h × €45\ntotal\nwith contingency: prev + 10%", modified: base - 86_400),
            Sheet(text: "# Monthly budget\nrent = 950\ngroceries = 420\nutilities = 135\ntotal", modified: base - 3 * 86_400),
            Sheet(text: "# Half marathon plan\nrace = 21.0975 km\nrace in mi\npace = 5.5 min\n21.0975 × pace\nprev in h", modified: base - 6 * 86_400),
            Sheet(text: "# Physics homework\ng = 9.81\nt = 2.5\n0.5 × g × t^2\nsin(30°)", modified: base - 9 * 86_400),
        ]
    }()
}
