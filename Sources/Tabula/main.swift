import AppKit
import Kit
import SwiftUI

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
    let model = TabulaModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "tablecells", accessibilityLabel: "Tabula") {
            TabulaView().environmentObject(self.model)
        }
    }
}

// MARK: - Parsing

enum ColumnAlignment: String, CaseIterable, Codable {
    case none = "None", left = "Left", center = "Centre", right = "Right"

    var symbol: String {
        switch self {
        case .none: "minus"
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        }
    }

    var rule: (String) -> String {
        switch self {
        case .none: { $0 }
        case .left: { ":" + $0.dropFirst() }
        case .center: { ":" + $0.dropFirst().dropLast() + ":" }
        case .right: { $0.dropLast() + ":" }
        }
    }
}

enum Format: Equatable {
    case markdown, delimited(Character)

    var name: String {
        switch self {
        case .markdown: "Markdown"
        case .delimited("\t"): "TSV"
        case .delimited(";"): "CSV (semicolons)"
        case .delimited: "CSV"
        }
    }
}

struct Table: Equatable {
    var rows: [[String]]
    var alignments: [ColumnAlignment] = []

    var columns: Int { rows.map(\.count).max() ?? 0 }

    /// Every row padded to the same number of cells.
    var normalized: [[String]] {
        let n = columns
        return rows.map { $0 + Array(repeating: "", count: max(0, n - $0.count)) }
    }
}

enum TableCodec {
    /// Guesses the format: a Markdown table has a pipe row followed by a separator row.
    static func detect(_ text: String) -> Format? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        if lines.count >= 2, lines[0].contains("|"), isSeparatorRow(lines[1]) { return .markdown }
        // Count delimiters outside quotes on the first line.
        let first = lines[0]
        var counts: [Character: Int] = ["\t": 0, ",": 0, ";": 0]
        var quoted = false
        for c in first {
            if c == "\"" { quoted.toggle() } else if !quoted, counts[c] != nil { counts[c]! += 1 }
        }
        if counts["\t"]! > 0 { return .delimited("\t") }
        if counts[";"]! > counts[","]! { return .delimited(";") }
        if counts[","]! > 0 { return .delimited(",") }
        return nil
    }

    /// RFC 4180 parsing: quoted fields may hold delimiters, doubled quotes and line breaks.
    static func parseDelimited(_ text: String, delimiter: Character) -> Table {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var atFieldStart = true
        var chars = Array(text)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        func endField() { row.append(field); field = ""; atFieldStart = true }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && atFieldStart {
                quoted = true
                atFieldStart = false
            } else if c == delimiter {
                endField()
            } else if c == "\r\n" || c == "\n" || c == "\r" {
                endRow()
            } else {
                field.append(c)
                atFieldStart = false
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return Table(rows: rows)
    }

    static func isSeparatorRow(_ line: String) -> Bool {
        let cells = splitMarkdownRow(line)
        return !cells.isEmpty && cells.allSatisfy { cell in
            let t = cell.trimmingCharacters(in: .whitespaces)
            return t.contains("-") && t.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    /// Splits "| a | b \| c |" into cells, honouring escaped pipes.
    static func splitMarkdownRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for c in t {
            if escaped { cell.append(c == "|" ? "|" : "\\" + String(c)); escaped = false; continue }
            if c == "\\" { escaped = true } else if c == "|" { cells.append(cell); cell = "" } else { cell.append(c) }
        }
        if escaped { cell.append("\\") }
        cells.append(cell)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func parseMarkdown(_ text: String) -> Table {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { $0.contains("|") }
        var rows: [[String]] = []
        var alignments: [ColumnAlignment] = []
        for (i, line) in lines.enumerated() {
            if i == 1 && isSeparatorRow(line) {
                alignments = splitMarkdownRow(line).map { cell in
                    let t = cell.trimmingCharacters(in: .whitespaces)
                    switch (t.hasPrefix(":"), t.hasSuffix(":")) {
                    case (true, true): return .center
                    case (true, false): return .left
                    case (false, true): return .right
                    default: return .none
                    }
                }
                continue
            }
            rows.append(splitMarkdownRow(line).map { $0.replacingOccurrences(of: "<br>", with: "\n") })
        }
        return Table(rows: rows, alignments: alignments)
    }

    static func markdown(_ table: Table, alignment: ColumnAlignment, pad: Bool = true) -> String {
        let rows = table.normalized.map { row in
            row.map { $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\r\n", with: "<br>")
                .replacingOccurrences(of: "\n", with: "<br>") }
        }
        guard let header = rows.first else { return "" }
        let widths = (0..<header.count).map { col in max(3, rows.map { $0[col].count }.max() ?? 0) }
        func line(_ cells: [String]) -> String {
            "| " + cells.enumerated().map { col, cell in
                guard pad else { return cell }
                let space = widths[col] - cell.count
                switch alignment {
                case .right: return String(repeating: " ", count: space) + cell
                case .center: return String(repeating: " ", count: space / 2) + cell + String(repeating: " ", count: space - space / 2)
                default: return cell + String(repeating: " ", count: space)
                }
            }.joined(separator: " | ") + " |"
        }
        let separator = "| " + widths.map { alignment.rule(String(repeating: "-", count: pad ? $0 : 3)) }.joined(separator: " | ") + " |"
        return ([line(header), separator] + rows.dropFirst().map(line)).joined(separator: "\n")
    }

    static func delimited(_ table: Table, delimiter: Character) -> String {
        table.normalized.map { row in
            row.map { cell in
                let needsQuotes = cell.contains(delimiter) || cell.contains("\"") || cell.contains("\n") || cell.contains("\r")
                    || cell.hasPrefix(" ") || cell.hasSuffix(" ")
                return needsQuotes ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : cell
            }.joined(separator: String(delimiter))
        }.joined(separator: "\n")
    }
}

// MARK: - Model

@MainActor
final class TabulaModel: ObservableObject {
    @Published private(set) var source = ""
    @AppStorage("alignment") var alignment: ColumnAlignment = .none { willSet { objectWillChange.send() } }
    @AppStorage("useTabs") var useTabs = false { willSet { objectWillChange.send() } }
    @AppStorage("pad") var pad = true { willSet { objectWillChange.send() } }

    private let pasteboard = NSPasteboard.general
    private var lastChange = -1
    private var timer: Timer?

    init() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        guard pasteboard.changeCount != lastChange else { return }
        lastChange = pasteboard.changeCount
        withAnimation(.snappy) { source = pasteboard.string(forType: .string) ?? "" }
    }

    var format: Format? { TableCodec.detect(source) }

    var table: Table? {
        switch format {
        case .markdown: TableCodec.parseMarkdown(source)
        case .delimited(let d): TableCodec.parseDelimited(source, delimiter: d)
        case nil: nil
        }
    }

    var output: String {
        guard let table, let format else { return "" }
        if format == .markdown { return TableCodec.delimited(table, delimiter: useTabs ? "\t" : ",") }
        return TableCodec.markdown(table, alignment: alignment, pad: pad)
    }

    var targetName: String { format == .markdown ? (useTabs ? "TSV" : "CSV") : "Markdown" }

    func convert() {
        let text = output
        guard !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChange = pasteboard.changeCount
        HUD.show(symbol: "tablecells.fill", title: "Copied as \(targetName)", tint: Color.tabula[1])
    }
}

extension Color {
    static let tabula = [Color(red: 0.95, green: 0.62, blue: 0.42), Color(red: 0.68, green: 0.3, blue: 0.16)]
}

// MARK: - Views

struct TabulaView: View {
    @EnvironmentObject var model: TabulaModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Tabula").font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer()
                if let format = model.format, let table = model.table {
                    Text("\(format.name) · \(table.rows.count) × \(table.columns)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.tabula[1])
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.tabula[0].opacity(0.18)))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            if let table = model.table, !table.rows.isEmpty {
                TablePreview(table: table)
                    .padding(.horizontal, 12)
                options
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                ScrollView([.vertical, .horizontal]) {
                    Text(model.output)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(10)
                }
                .frame(height: 130)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.4)))
                .padding(.horizontal, 12)
                Button { model.convert() } label: { Label("Copy as \(model.targetName)", systemImage: "arrow.left.arrow.right") }
                    .buttonStyle(PillButtonStyle(Color.tabula))
                    .keyboardShortcut(.return, modifiers: [])
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "tablecells").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("Copy a CSV, a spreadsheet range or a Markdown table,\nand it will show up here ready to convert.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 240)
            }

            Divider().opacity(0.5)
            PanelFooter(name: "Tabula") {
                Toggle("Pad Markdown Columns", isOn: $model.pad)
                Toggle("Write Tabs Instead of Commas", isOn: $model.useTabs)
            }
        }
        .frame(width: 380)
    }

    @ViewBuilder private var options: some View {
        if model.format == .markdown {
            HStack {
                Text("Output").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $model.useTabs) {
                    Text("Commas").tag(false)
                    Text("Tabs").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
        } else {
            HStack {
                Text("Align").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $model.alignment) {
                    ForEach(ColumnAlignment.allCases, id: \.self) { a in
                        Image(systemName: a.symbol).help(a.rawValue).tag(a)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
            }
        }
    }
}

/// The first rows of the table, drawn as a real grid.
struct TablePreview: View {
    let table: Table
    private let maxRows = 5, maxColumns = 5

    var body: some View {
        let rows = table.normalized
        let cols = min(table.columns, maxColumns)
        VStack(spacing: 0) {
            ForEach(Array(rows.prefix(maxRows).enumerated()), id: \.offset) { r, row in
                PreviewRow(cells: Array(row.prefix(cols)), header: r == 0, shaded: r % 2 == 0, alignments: table.alignments)
                if r < min(rows.count, maxRows) - 1 { Divider().opacity(0.4) }
            }
            if rows.count > maxRows || table.columns > maxColumns {
                Text(moreLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
    }

    private var moreLabel: String {
        var parts: [String] = []
        if table.rows.count > maxRows { parts.append("\(table.rows.count - maxRows) more rows") }
        if table.columns > maxColumns { parts.append("\(table.columns - maxColumns) more columns") }
        return parts.joined(separator: ", ")
    }
}

struct PreviewRow: View {
    let cells: [String]
    let header: Bool
    let shaded: Bool
    let alignments: [ColumnAlignment]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { c, cell in
                Text(cell.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11.5, weight: header ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: alignment(c))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                if c < cells.count - 1 { Divider().opacity(0.6) }
            }
        }
        .background(background)
    }

    private var background: Color {
        if header { return Color.tabula[0].opacity(0.2) }
        return Color.primary.opacity(shaded ? 0.05 : 0.02)
    }

    private func alignment(_ col: Int) -> Alignment {
        guard col < alignments.count else { return .leading }
        switch alignments[col] {
        case .center: return .center
        case .right: return .trailing
        default: return .leading
        }
    }
}

// MARK: - Icon

//: a table whose header row folds into Markdown pipes

func appIcon() -> NSBitmapImageRep {
    render(0x8EA3C2, 0x2F405A) { ctx in
        let sheet = CGRect(x: 222, y: 262, width: 580, height: 500)
        ctx.saveGState()
        shadow(ctx, y: -18, blur: 34, alpha: 0.3)
        ctx.addPath(roundedRect(sheet, 54))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(roundedRect(sheet, 54))
        ctx.clip()
        // Header band.
        gradient([rgb(0xF08A5D), rgb(0xD0603A)], from: CGPoint(x: 0, y: sheet.maxY), to: CGPoint(x: 0, y: sheet.maxY - 125), in: ctx)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: sheet.minX, y: sheet.minY, width: sheet.width, height: sheet.height - 125))
        // Zebra rows.
        ctx.setFillColor(rgb(0xFBEDE5).cgColor)
        for i in [1, 3] {
            ctx.fill(CGRect(x: sheet.minX, y: sheet.maxY - 125 - CGFloat(i + 1) * 94, width: sheet.width, height: 94))
        }
        // Column rules.
        ctx.setFillColor(rgb(0xE9C7B6).cgColor)
        for x in [sheet.minX + 193, sheet.minX + 387] {
            ctx.fill(CGRect(x: x - 3, y: sheet.minY, width: 6, height: sheet.height - 125))
        }
        // Cell contents as soft bars.
        ctx.setLineCap(.round)
        ctx.setLineWidth(22)
        ctx.setStrokeColor(rgb(0xC9A595).cgColor)
        for r in 0..<4 {
            let y = sheet.maxY - 125 - 47 - CGFloat(r) * 94
            for (c, w) in [(0, 110.0), (1, 80.0), (2, 120.0)] {
                let x = sheet.minX + 40 + CGFloat(c) * 193
                ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + w - CGFloat((r * 23 + c * 17) % 40), y: y))
            }
        }
        ctx.strokePath()
        // Header pipes in white.
        ctx.setLineWidth(18)
        ctx.setStrokeColor(NSColor.white.cgColor)
        for x in [sheet.minX + 193, sheet.minX + 387] {
            ctx.move(to: CGPoint(x: x, y: sheet.maxY - 30)); ctx.addLine(to: CGPoint(x: x, y: sheet.maxY - 95))
        }
        ctx.strokePath()
        ctx.setLineWidth(24)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        for c in 0..<3 {
            let x = sheet.minX + 40 + CGFloat(c) * 193
            ctx.move(to: CGPoint(x: x, y: sheet.maxY - 62)); ctx.addLine(to: CGPoint(x: x + 100, y: sheet.maxY - 62))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
}
