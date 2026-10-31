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
    let model = CompareModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "arrow.left.and.right.text.vertical", accessibilityLabel: "Compare") {
            CompareView().environmentObject(self.model)
        }
    }
}

// MARK: - Model

enum Edit: Equatable {
    case equal(Int, Int) // Index in old, index in new.
    case delete(Int)
    case insert(Int)
}

enum Myers {
    /// A shortest edit script from `a` to `b` (Myers 1986), after trimming the common prefix and suffix.
    static func diff<T: Equatable>(_ a: [T], _ b: [T]) -> [Edit] {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let ma = Array(a[prefix..<(a.count - suffix)]), mb = Array(b[prefix..<(b.count - suffix)])
        var edits = (0..<prefix).map { Edit.equal($0, $0) }
        edits += core(ma, mb).map {
            switch $0 {
            case .equal(let i, let j): .equal(i + prefix, j + prefix)
            case .delete(let i): .delete(i + prefix)
            case .insert(let j): .insert(j + prefix)
            }
        }
        edits += (0..<suffix).map { .equal(a.count - suffix + $0, b.count - suffix + $0) }
        return edits
    }

    private static func core<T: Equatable>(_ a: [T], _ b: [T]) -> [Edit] {
        let n = a.count, m = b.count
        if n == 0 { return (0..<m).map { .insert($0) } }
        if m == 0 { return (0..<n).map { .delete($0) } }
        let max = n + m, offset = max
        var v = [Int](repeating: 0, count: 2 * max + 2)
        var trace: [[Int]] = []
        search: for d in 0...max {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n, y < m, a[x] == b[y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n && y >= m { trace.append(v); break search }
            }
        }
        // Walk the trace backwards to recover the path.
        var edits: [Edit] = []
        var x = n, y = m
        for d in stride(from: trace.count - 2, through: 0, by: -1) {
            let v = trace[d]
            let k = x - y
            let prevK = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? k + 1 : k - 1
            let prevX = v[offset + prevK], prevY = prevX - prevK
            while x > prevX, y > prevY { x -= 1; y -= 1; edits.append(.equal(x, y)) }
            if d > 0 {
                if x == prevX { y -= 1; edits.append(.insert(y)) } else { x -= 1; edits.append(.delete(x)) }
            }
        }
        while x > 0, y > 0 { x -= 1; y -= 1; edits.append(.equal(x, y)) }
        return edits.reversed()
    }
}

struct Span: Equatable {
    var text: String
    var changed: Bool
}

enum LineKind { case equal, delete, insert }

struct DiffLine: Equatable, Identifiable {
    var id: Int
    var kind: LineKind
    var oldNumber: Int?
    var newNumber: Int?
    var spans: [Span]
    var text: String { spans.map(\.text).joined() }
}

struct SideRow: Identifiable {
    var id: Int
    var left: DiffLine?
    var right: DiffLine?
}

struct DiffResult {
    var lines: [DiffLine] = []
    var rows: [SideRow] = []
    var added = 0
    var removed = 0

    var unified: String {
        lines.map { ($0.kind == .equal ? " " : $0.kind == .delete ? "-" : "+") + $0.text }.joined(separator: "\n")
    }
}

enum TextDiff {
    /// Words, runs of spaces, and single punctuation marks.
    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var kind = 0 // 1 word, 2 space
        for ch in s {
            let k = ch.isLetter || ch.isNumber || ch == "_" ? 1 : ch.isWhitespace ? 2 : 3
            if k == kind && k != 3 { current.append(ch); continue }
            if !current.isEmpty { out.append(current) }
            current = String(ch)
            kind = k
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Spans of `old` and `new` with the changed words marked, merging neighbours of the same state.
    static func words(_ old: String, _ new: String) -> ([Span], [Span]) {
        let a = tokens(old), b = tokens(new)
        var left: [Span] = [], right: [Span] = []
        func push(_ spans: inout [Span], _ text: String, _ changed: Bool) {
            if let last = spans.last, last.changed == changed { spans[spans.count - 1].text += text } else { spans.append(Span(text: text, changed: changed)) }
        }
        for e in Myers.diff(a, b) {
            switch e {
            case .equal(let i, let j): push(&left, a[i], false); push(&right, b[j], false)
            case .delete(let i): push(&left, a[i], true)
            case .insert(let j): push(&right, b[j], true)
            }
        }
        return (left, right)
    }

    static func lines(_ s: String) -> [String] {
        s.isEmpty ? [] : s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    static func compare(_ old: String, _ new: String, ignoreWhitespace: Bool) -> DiffResult {
        let a = lines(old), b = lines(new)
        let key: (String) -> String = ignoreWhitespace ? { $0.filter { !$0.isWhitespace } } : { $0 }
        let edits = Myers.diff(a.map(key), b.map(key))
        var result = DiffResult()
        var pendingDeletes: [Int] = [], pendingInserts: [Int] = []
        func flush() {
            // Pair deletions with insertions in order, for word highlights and side by side rows.
            let paired = min(pendingDeletes.count, pendingInserts.count)
            var deleteLines: [DiffLine] = [], insertLines: [DiffLine] = []
            for (n, i) in pendingDeletes.enumerated() {
                let spans = n < paired ? words(a[i], b[pendingInserts[n]]).0 : [Span(text: a[i], changed: false)]
                deleteLines.append(DiffLine(id: 0, kind: .delete, oldNumber: i + 1, newNumber: nil, spans: spans))
            }
            for (n, j) in pendingInserts.enumerated() {
                let spans = n < paired ? words(a[pendingDeletes[n]], b[j]).1 : [Span(text: b[j], changed: false)]
                insertLines.append(DiffLine(id: 0, kind: .insert, oldNumber: nil, newNumber: j + 1, spans: spans))
            }
            for l in deleteLines + insertLines {
                var l = l
                l.id = result.lines.count
                result.lines.append(l)
            }
            for r in 0..<max(deleteLines.count, insertLines.count) {
                result.rows.append(SideRow(id: result.rows.count, left: r < deleteLines.count ? deleteLines[r] : nil,
                                           right: r < insertLines.count ? insertLines[r] : nil))
            }
            result.removed += pendingDeletes.count
            result.added += pendingInserts.count
            pendingDeletes = []
            pendingInserts = []
        }
        for e in edits {
            switch e {
            case .delete(let i): pendingDeletes.append(i)
            case .insert(let j): pendingInserts.append(j)
            case .equal(let i, let j):
                flush()
                let line = DiffLine(id: result.lines.count, kind: .equal, oldNumber: i + 1, newNumber: j + 1, spans: [Span(text: b[j], changed: false)])
                result.lines.append(line)
                result.rows.append(SideRow(id: result.rows.count, left: line, right: line))
            }
        }
        flush()
        return result
    }
}

@MainActor
final class CompareModel: ObservableObject {
    @Published var left = """
    The quick brown fox
    jumps over the lazy dog.
    Pack my box with
    five dozen liquor jugs.
    """
    @Published var right = """
    The quick red fox
    jumps over the lazy dog.
    Pack my box with
    six dozen liquor jugs!
    Sphinx of black quartz.
    """
    @AppStorage("sideBySide") var sideBySide = false
    @AppStorage("ignoreWhitespace") var ignoreWhitespace = false

    var result: DiffResult { TextDiff.compare(left, right, ignoreWhitespace: ignoreWhitespace) }

    func swap() { (left, right) = (right, left) }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Views

struct CompareView: View {
    @EnvironmentObject var model: CompareModel

    var body: some View {
        let result = model.result
        VStack(spacing: 0) {
            header(result)
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    InputPane(title: "Original", text: $model.left)
                    InputPane(title: "Changed", text: $model.right)
                }
                OptionsBar(result: result)
                ResultView(result: result)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            Divider().opacity(0.5)
            PanelFooter(name: "Compare") {
                Button("Swap Sides") { model.swap() }
                Button("Copy Unified Diff") { model.copy(result.unified) }
                Button("Clear Both") { model.left = ""; model.right = "" }
            }
        }
        .frame(width: 400)
    }

    private func header(_ result: DiffResult) -> some View {
        HStack(spacing: 8) {
            Text("Compare").font(.system(size: 17, weight: .bold, design: .rounded))
            Spacer()
            CountChip(value: result.added, sign: "+", color: .green)
            CountChip(value: result.removed, sign: "\u{2212}", color: .red)
            GlassIconButton("arrow.left.arrow.right", help: "Swap sides") { withAnimation(.snappy) { model.swap() } }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct CountChip: View {
    let value: Int
    let sign: String
    let color: Color

    var body: some View {
        Text("\(sign)\(value)")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.13)))
            .animation(.snappy, value: value)
    }
}

struct InputPane: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                IconButton("doc.on.clipboard", help: "Paste") { text = NSPasteboard.general.string(forType: .string) ?? "" }
                IconButton("xmark", help: "Clear") { text = "" }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(3)
                if text.isEmpty {
                    Text("Paste text here").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 8).padding(.vertical, 3).allowsHitTesting(false)
                }
            }
            .frame(height: 96)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(0.3)))
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    init(_ symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 18)
                .background(Capsule().fill(.quaternary.opacity(hovering ? 0.8 : 0.4)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .onHover { hovering = $0 }
    }
}

struct OptionsBar: View {
    @EnvironmentObject var model: CompareModel
    let result: DiffResult
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Chip(title: "Unified", selected: !model.sideBySide) { model.sideBySide = false }
            Chip(title: "Side by side", selected: model.sideBySide) { model.sideBySide = true }
            Chip(title: "Ignore spaces", selected: model.ignoreWhitespace) { model.ignoreWhitespace.toggle() }
            Spacer(minLength: 0)
            Button {
                model.copy(result.unified)
                withAnimation { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copied = false } }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            .help("Copy the unified diff")
        }
    }
}

struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button { withAnimation(.snappy(duration: 0.2)) { action() } } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(selected ? .white : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(selected ? AnyShapeStyle(Color.accentGradient) : AnyShapeStyle(.quaternary.opacity(0.4))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct ResultView: View {
    @EnvironmentObject var model: CompareModel
    let result: DiffResult

    var body: some View {
        Group {
            if model.left.isEmpty && model.right.isEmpty {
                placeholder("text.badge.plus", "Paste two versions above to see what changed.")
            } else if result.added == 0 && result.removed == 0 {
                placeholder("checkmark.circle", model.ignoreWhitespace ? "The texts match, ignoring spaces." : "The texts are identical.")
            } else {
                ScrollView([.vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        if model.sideBySide {
                            ForEach(result.rows) { row in
                                HStack(spacing: 2) {
                                    LineView(line: row.left, side: .left)
                                    LineView(line: row.right, side: .right)
                                }
                            }
                        } else {
                            ForEach(result.lines) { LineView(line: $0, side: .unified) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(height: 220)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func placeholder(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LineView: View {
    enum Side { case left, right, unified }
    let line: DiffLine?
    let side: Side

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            if let line {
                Text(number(line)).foregroundStyle(.tertiary).frame(width: side == .unified ? 46 : 20, alignment: .trailing)
                Text(sign(line)).foregroundStyle(color(line)).frame(width: 9)
                Text(Self.attributed(line))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Spacer()
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 1.5)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(line.map { color($0).opacity($0.kind == .equal ? 0 : 0.1) } ?? Color.secondary.opacity(0.05))
    }

    private func number(_ l: DiffLine) -> String {
        switch side {
        case .left: l.oldNumber.map(String.init) ?? ""
        case .right: l.newNumber.map(String.init) ?? ""
        case .unified: String(format: "%3@ %3@", l.oldNumber.map(String.init) ?? "", l.newNumber.map(String.init) ?? "")
        }
    }

    private func sign(_ l: DiffLine) -> String { l.kind == .delete ? "\u{2212}" : l.kind == .insert ? "+" : "" }

    private func color(_ l: DiffLine) -> Color { l.kind == .delete ? .red : l.kind == .insert ? .green : .primary }

    static func attributed(_ l: DiffLine) -> AttributedString {
        var out = AttributedString()
        for span in l.spans {
            var a = AttributedString(span.text)
            if span.changed {
                a.backgroundColor = (l.kind == .delete ? Color.red : Color.green).opacity(0.3)
                a.font = .system(size: 11, weight: .semibold, design: .monospaced)
            }
            out += a
        }
        return out
    }
}

extension Color {
    static let accentGradient = LinearGradient(colors: [Color(red: 0.99, green: 0.6, blue: 0.3), Color(red: 0.92, green: 0.35, blue: 0.05)],
                                               startPoint: .top, endPoint: .bottom)
}

// MARK: - Icon

//: two overlapping pages, their lines marked in diff red and green

func appIcon() -> NSBitmapImageRep {
    render(0xFED7AA, 0xEA580C) { ctx in
        func page(_ rect: CGRect, angle: CGFloat, marks: [(Int, UInt32)]) {
            ctx.saveGState()
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: angle * .pi / 180)
            let r = CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
            ctx.saveGState()
            shadow(ctx, y: -16, blur: 32, alpha: 0.28)
            ctx.addPath(roundedRect(r, 44))
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            for i in 0..<6 {
                let y = r.maxY - 90 - CGFloat(i) * 68
                if let mark = marks.first(where: { $0.0 == i }) {
                    ctx.setFillColor(rgb(mark.1, 0.22).cgColor)
                    ctx.fill(CGRect(x: r.minX, y: y - 30, width: r.width, height: 60))
                    ctx.setFillColor(rgb(mark.1).cgColor)
                    ctx.fill(CGRect(x: r.minX, y: y - 30, width: 14, height: 60))
                }
                ctx.setStrokeColor(rgb(marks.contains { $0.0 == i } ? 0x57534E : 0xD6D3D1).cgColor)
                ctx.setLineWidth(20)
                ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: r.minX + 50, y: y))
                ctx.addLine(to: CGPoint(x: r.minX + 50 + [250, 200, 270, 180, 240, 150][i], y: y))
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
        page(CGRect(x: 170, y: 250, width: 380, height: 500), angle: 6, marks: [(1, 0xEF4444), (4, 0xEF4444)])
        page(CGRect(x: 470, y: 250, width: 380, height: 500), angle: -6, marks: [(1, 0x22C55E), (2, 0x22C55E)])
    }
}
