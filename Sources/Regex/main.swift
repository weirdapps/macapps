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
    let model = RegexModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "asterisk.circle", accessibilityLabel: "Regex") {
            RegexView().environmentObject(self.model)
        }
    }
}

// MARK: - Model

struct Flags: OptionSet, Hashable {
    let rawValue: Int
    static let caseInsensitive = Flags(rawValue: 1)
    static let multiline = Flags(rawValue: 2)
    static let dotAll = Flags(rawValue: 4)
    static let extended = Flags(rawValue: 8)

    var options: NSRegularExpression.Options {
        var o: NSRegularExpression.Options = []
        if contains(.caseInsensitive) { o.insert(.caseInsensitive) }
        if contains(.multiline) { o.insert(.anchorsMatchLines) }
        if contains(.dotAll) { o.insert(.dotMatchesLineSeparators) }
        if contains(.extended) { o.insert(.allowCommentsAndWhitespace) }
        return o
    }

    /// The letters as written after a /pattern/.
    var letters: String {
        [(Flags.caseInsensitive, "i"), (.multiline, "m"), (.dotAll, "s"), (.extended, "x")].filter { contains($0.0) }.map(\.1).joined()
    }
}

struct Group: Equatable {
    var index: Int
    var name: String?
    var range: NSRange // location NSNotFound when the group did not take part.
    var value: String?
}

struct Match: Equatable {
    var range: NSRange
    var groups: [Group] // Group 0 is the whole match.
}

struct Outcome: Equatable {
    var matches: [Match] = []
    var truncated = false
    var replaced: String?
    var error: String?
}

enum RegexEngine {
    static let limit = 5000

    static func run(pattern: String, flags: Flags, text: String, template: String?) -> Outcome {
        guard !pattern.isEmpty else { return Outcome() }
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: flags.options)
        } catch {
            return Outcome(error: describe(error, pattern: pattern))
        }
        let ns = text as NSString
        let names = namedGroupNumbers(pattern)
        var out = Outcome()
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { result, _, stop in
            guard let result else { return }
            if out.matches.count == limit { out.truncated = true; stop.pointee = true; return }
            var groups: [Group] = []
            for i in 0..<result.numberOfRanges {
                let r = result.range(at: i)
                groups.append(Group(index: i, name: nil, range: r, value: r.location == NSNotFound ? nil : ns.substring(with: r)))
            }
            for (name, n) in names where n < groups.count { groups[n].name = name }
            out.matches.append(Match(range: result.range, groups: groups))
        }
        if let template {
            out.replaced = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length),
                                                          withTemplate: expandNames(template, names: names))
        }
        return out
    }

    /// NSRegularExpression templates know $1 but not ${name}; turn names into numbers.
    static func expandNames(_ template: String, names: [String: Int]) -> String {
        var result = template
        for (name, n) in names { result = result.replacingOccurrences(of: "${\(name)}", with: "$\(n)") }
        return result
    }

    /// Numbers each capturing group by the position of its opening parenthesis, as ICU does.
    static func namedGroupNumbers(_ pattern: String) -> [String: Int] {
        let chars = Array(pattern)
        var numbers: [String: Int] = [:]
        var count = 0
        var i = 0
        var inClass = false
        while i < chars.count {
            let c = chars[i]
            if c == "\\" { i += 2; continue }
            if inClass { if c == "]" { inClass = false }; i += 1; continue }
            if c == "[" { inClass = true; i += 1; continue }
            if c == "(" {
                if i + 1 < chars.count, chars[i + 1] == "?" {
                    if i + 2 < chars.count, chars[i + 2] == "<", i + 3 < chars.count, chars[i + 3] != "=", chars[i + 3] != "!" {
                        count += 1
                        let start = i + 3
                        if let end = chars[start...].firstIndex(of: ">") { numbers[String(chars[start..<end])] = count }
                    }
                } else {
                    count += 1
                }
            }
            i += 1
        }
        return numbers
    }

    static func describe(_ error: Error, pattern: String) -> String {
        let ns = error as NSError
        var text = "The pattern is not valid."
        if let detail = ns.userInfo["NSInvalidValue"] as? String, detail != pattern { text += " Near \u{201C}\(detail)\u{201D}." }
        // Common slips, explained in words.
        var depth = 0
        var escaped = false
        for c in pattern {
            if escaped { escaped = false; continue }
            if c == "\\" { escaped = true } else if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }
        }
        if depth > 0 { return "An opening parenthesis is never closed." }
        if depth < 0 { return "A closing parenthesis has no opening one." }
        if escaped { return "The pattern ends with a lone backslash." }
        if pattern.filter({ $0 == "[" }).count > pattern.filter({ $0 == "]" }).count { return "A character class [ is never closed." }
        if pattern.first.map({ "*+?".contains($0) }) == true { return "\u{201C}\(pattern.first!)\u{201D} has nothing to repeat." }
        return text
    }
}

@MainActor
final class RegexModel: ObservableObject {
    @AppStorage("pattern") var pattern = #"(?<user>[\w.+-]+)@(?<domain>[\w-]+(?:\.[\w-]+)+)"# { didSet { refresh() } }
    @AppStorage("flags") var flagBits = 0 { didSet { refresh() } }
    @AppStorage("replacement") var replacement = "${user} at $2" { didSet { refresh() } }
    @AppStorage("sample") var sample = """
    Write to ada@example.com or grace.hopper@navy.mil.
    Bounces go to postmaster@mail.example.org.
    """ { didSet { refresh() } }
    @Published private(set) var outcome = Outcome()
    @Published var selected = 0

    private var generation = 0

    init() {
        outcome = RegexEngine.run(pattern: pattern, flags: flags, text: sample, template: replacement)
    }

    var flags: Flags {
        get { Flags(rawValue: flagBits) }
        set { flagBits = newValue.rawValue }
    }

    func toggle(_ flag: Flags) {
        var f = flags
        if f.contains(flag) { f.remove(flag) } else { f.insert(flag) }
        flags = f
    }

    /// Matching runs off the main thread, so a runaway pattern cannot freeze the panel.
    private func refresh() {
        generation += 1
        let mine = generation
        let (p, f, t, r) = (pattern, flags, sample, replacement)
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = RegexEngine.run(pattern: p, flags: f, text: t, template: r)
            await self?.apply(result, generation: mine)
        }
    }

    private func apply(_ result: Outcome, generation mine: Int) {
        guard mine == generation else { return }
        outcome = result
        if selected >= result.matches.count { selected = max(0, result.matches.count - 1) }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Views

struct RegexView: View {
    @EnvironmentObject var model: RegexModel

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 10) {
                PatternField()
                SampleEditor()
                GroupTable()
                ReplacementPane()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            Divider().opacity(0.5)
            PanelFooter(name: "Regex") {
                Button("Paste Sample Text") { model.sample = NSPasteboard.general.string(forType: .string) ?? "" }
                Button("Copy Pattern") { model.copy(model.pattern) }
                Button("Copy All Matches") { model.copy(model.outcome.matches.compactMap { $0.groups.first?.value }.joined(separator: "\n")) }
            }
        }
        .frame(width: 400)
    }

    private var header: some View {
        HStack {
            Text("Regex").font(.system(size: 17, weight: .bold, design: .rounded))
            Spacer()
            let n = model.outcome.matches.count
            Text(model.outcome.error != nil ? "Error" : "\(n)\(model.outcome.truncated ? "+" : "") match\(n == 1 ? "" : "es")")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(model.outcome.error != nil ? Color.orange : n > 0 ? Color.accentTint : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill((model.outcome.error != nil ? Color.orange : n > 0 ? Color.accentTint : .secondary).opacity(0.13)))
                .animation(.snappy, value: n)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct PatternField: View {
    @EnvironmentObject var model: RegexModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text("/").foregroundStyle(.tertiary)
                TextField("Pattern", text: $model.pattern)
                    .textFieldStyle(.plain)
                Text("/" + model.flags.letters).foregroundStyle(.tertiary)
            }
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(model.outcome.error == nil ? 0 : 0.7), lineWidth: 1.5))
            HStack(spacing: 5) {
                FlagChip(title: "Ignore case", flag: .caseInsensitive)
                FlagChip(title: "Multiline", flag: .multiline)
                FlagChip(title: "Dot all", flag: .dotAll)
                FlagChip(title: "Extended", flag: .extended)
            }
            if let error = model.outcome.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.2), value: model.outcome.error)
    }
}

struct FlagChip: View {
    @EnvironmentObject var model: RegexModel
    let title: String
    let flag: Flags

    var body: some View {
        let on = model.flags.contains(flag)
        Button { withAnimation(.snappy) { model.toggle(flag) } } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(on ? .white : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(on ? AnyShapeStyle(Color.accentGradient) : AnyShapeStyle(.quaternary.opacity(0.4))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Flag \(Flags(rawValue: flag.rawValue).letters)")
    }
}

struct SampleEditor: View {
    @EnvironmentObject var model: RegexModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text("Test text").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                PaneButton("doc.on.clipboard", "Paste") { model.sample = NSPasteboard.general.string(forType: .string) ?? "" }
                PaneButton("xmark", "Clear") { model.sample = "" }
            }
            HighlightingEditor(text: $model.sample, matches: model.outcome.matches, selected: model.selected)
                .frame(height: 112)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// An editable text view that paints every match, and the selected match's groups, behind the text.
struct HighlightingEditor: NSViewRepresentable {
    @Binding var text: String
    let matches: [Match]
    let selected: Int

    static let groupColors: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPink, .systemTeal, .systemYellow]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.textContainerInset = NSSize(width: 4, height: 7)
        view.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let view = scroll.documentView as! NSTextView
        if view.string != text { view.string = text }
        guard let storage = view.textStorage else { return }
        let length = (storage.string as NSString).length
        let whole = NSRange(location: 0, length: length)
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: whole)
        storage.removeAttribute(.underlineStyle, range: whole)
        storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular), range: whole)
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: whole)
        for (n, match) in matches.enumerated() where NSMaxRange(match.range) <= length {
            let isSelected = n == selected
            storage.addAttribute(.backgroundColor, value: NSColor.systemPurple.withAlphaComponent(isSelected ? 0.32 : 0.16), range: match.range)
            guard isSelected else { continue }
            for g in match.groups.dropFirst() where g.range.location != NSNotFound && NSMaxRange(g.range) <= length {
                let color = Self.groupColors[(g.index - 1) % Self.groupColors.count]
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue, range: g.range)
                storage.addAttribute(.underlineColor, value: color, range: g.range)
            }
        }
        storage.endEditing()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HighlightingEditor
        init(_ parent: HighlightingEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}

struct GroupTable: View {
    @EnvironmentObject var model: RegexModel

    var body: some View {
        let matches = model.outcome.matches
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Groups").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if matches.count > 1 {
                    Button { model.selected = (model.selected - 1 + matches.count) % matches.count } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.plain)
                    Text("Match \(model.selected + 1) of \(matches.count)")
                        .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                    Button { model.selected = (model.selected + 1) % matches.count } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.plain)
                }
            }
            .foregroundStyle(.secondary)
            .font(.system(size: 10, weight: .bold))
            VStack(spacing: 2) {
                if model.selected < matches.count {
                    ForEach(matches[model.selected].groups, id: \.index) { g in
                        GroupRow(group: g)
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "text.magnifyingglass").foregroundStyle(.tertiary)
                        Text(model.pattern.isEmpty ? "Type a pattern to start matching." : "No matches in the test text.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
        }
    }
}

struct GroupRow: View {
    @EnvironmentObject var model: RegexModel
    let group: Group
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                if group.index > 0 {
                    Capsule().fill(Color(nsColor: HighlightingEditor.groupColors[(group.index - 1) % HighlightingEditor.groupColors.count]))
                        .frame(width: 3, height: 12)
                }
                Text(group.index == 0 ? "Match" : group.name ?? "$\(group.index)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .frame(width: 72, alignment: .leading)
            Text(group.value.map { $0.isEmpty ? "(empty)" : $0 } ?? "(no match)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(group.value?.isEmpty == false ? .primary : .tertiary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if group.range.location != NSNotFound {
                Text("\(group.range.location)..<\(NSMaxRange(group.range))")
                    .font(.system(size: 10, design: .rounded)).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary.opacity(hovering ? 0.5 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { if let v = group.value { model.copy(v) } }
        .onHover { hovering = $0 }
        .help("Click to copy")
    }
}

struct ReplacementPane: View {
    @EnvironmentObject var model: RegexModel
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.swap").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Replace with, e.g. $1 or ${name}", text: $model.replacement)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                if let replaced = model.outcome.replaced, !model.replacement.isEmpty || !model.outcome.matches.isEmpty {
                    PaneButton(copied ? "checkmark" : "doc.on.doc", copied ? "Copied" : "Copy result") {
                        model.copy(replaced)
                        withAnimation { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copied = false } }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)
            if let replaced = model.outcome.replaced, model.outcome.error == nil {
                ScrollView {
                    Text(replaced)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(height: 54)
                .padding(.horizontal, 10)
            }
            Spacer(minLength: 0).frame(height: 4)
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
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
    static let accentTint = Color(red: 0.72, green: 0.2, blue: 0.78)
    static let accentGradient = LinearGradient(colors: [Color(red: 0.9, green: 0.5, blue: 0.98), Color(red: 0.63, green: 0.11, blue: 0.69)],
                                               startPoint: .top, endPoint: .bottom)
}

// MARK: - Icon

//: a dot and a star, the two most famous regex tokens, inside a magnifier lens over highlighted text

func appIcon() -> NSBitmapImageRep {
    render(0xF0ABFC, 0xA21CAF) { ctx in
        // Lines of text, one highlighted.
        ctx.setLineCap(.round)
        for (n, (x, w)) in [(200.0, 520.0), (200, 430), (200, 560), (200, 380)].enumerated() {
            let y = 720 - CGFloat(n) * 120
            if n == 2 {
                ctx.addPath(roundedRect(CGRect(x: x - 26, y: y - 42, width: w + 52, height: 84), 30))
                ctx.setFillColor(rgb(0xFDE047, 0.85).cgColor)
                ctx.fillPath()
            }
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(n == 2 ? 0.95 : 0.4).cgColor)
            ctx.setLineWidth(34)
            ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + w, y: y))
            ctx.strokePath()
        }
        // Magnifier.
        let c = CGPoint(x: 560, y: 520), r: CGFloat = 210
        ctx.saveGState()
        shadow(ctx, y: -18, blur: 36, alpha: 0.35)
        ctx.setStrokeColor(rgb(0x3B0764).cgColor)
        ctx.setLineWidth(86)
        ctx.move(to: CGPoint(x: c.x + r * 0.72, y: c.y - r * 0.72))
        ctx.addLine(to: CGPoint(x: c.x + r * 1.45, y: c.y - r * 1.45))
        ctx.strokePath()
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r - 30, y: c.y - r - 30, width: (r + 30) * 2, height: (r + 30) * 2))
        ctx.restoreGState()
        ctx.setFillColor(rgb(0xFAE8FF).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        // ".*" in the lens.
        ctx.setFillColor(rgb(0x86198F).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 120, y: c.y - 92, width: 66, height: 66))
        ctx.setStrokeColor(rgb(0x86198F).cgColor)
        ctx.setLineWidth(38)
        let s = CGPoint(x: c.x + 50, y: c.y + 30)
        for k in 0..<3 {
            let a = CGFloat(k) * .pi / 3 + .pi / 2
            ctx.move(to: CGPoint(x: s.x + cos(a) * 86, y: s.y + sin(a) * 86))
            ctx.addLine(to: CGPoint(x: s.x - cos(a) * 86, y: s.y - sin(a) * 86))
        }
        ctx.strokePath()
    }
}
