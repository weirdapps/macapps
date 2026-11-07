import AppKit
import Kit
import SwiftUI

enum Theme {
    static let green = Color(red: 0.24, green: 0.86, blue: 0.52)
    static let deep = Color(red: 0.07, green: 0.62, blue: 0.40)
    static let navy = Color(red: 0.11, green: 0.17, blue: 0.29)
    static let gradient = LinearGradient(colors: [green, deep], startPoint: .top, endPoint: .bottom)
    static let tileGradient = LinearGradient(colors: [navy, Color(red: 0.04, green: 0.06, blue: 0.13)], startPoint: .top, endPoint: .bottom)
    /// A leading timestamp in the common log formats: ISO 8601, `[dd/Mon/yyyy:hh:mm:ss +zz]`, syslog `Mon dd hh:mm:ss`, or a bare time.
    static let timestamp = try! NSRegularExpression(pattern:
        #"^\s*\[?(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?|\d{2}/\w{3}/\d{4}:\d{2}:\d{2}:\d{2}(?: [+-]\d{4})?|\w{3} +\d{1,2} \d{2}:\d{2}:\d{2}|\d{2}:\d{2}:\d{2}(?:[.,]\d+)?)\]?"#)
}

// MARK: - Window

struct ContentView: View {
    @ObservedObject var model: TailModel
    @State private var isTargeted = false

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 340)
        } detail: {
            if let source = model.selected {
                LogDetail(source: source, model: model)
            } else if model.sources.isEmpty {
                DropZone(symbol: "text.line.last.and.arrowtriangle.forward", title: "Follow a log file",
                         message: "Drop log files here, or open one. New lines appear the moment they are written.",
                         button: "Open Log…", tint: Theme.deep, isTargeted: isTargeted) { model.presentOpenPanel() }
                    .navigationTitle("Tail")
            } else {
                ContentUnavailableView("No log selected", systemImage: "sidebar.left",
                                       description: Text("Choose a log in the sidebar."))
                    .navigationTitle("Tail")
            }
        }
        .searchable(text: $model.filterText, placement: .toolbar, prompt: model.isRegex ? "Regular expression" : "Filter lines")
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .tint(Theme.deep)
        .frame(minWidth: 720, minHeight: 420)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var model: TailModel

    var body: some View {
        List(selection: $model.selection) {
            Section(model.sources.isEmpty ? "" : "Logs") {
                ForEach(model.sources) { source in
                    SourceRow(source: source)
                        .tag(source.id)
                        .contextMenu {
                            Button("Reveal in Finder") { revealInFinder([source.url]) }
                            Button(source.isPaused ? "Resume" : "Pause") { source.togglePause() }
                            Button("Clear") { source.clear() }
                            Divider()
                            Button("Close") { model.close(source) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button { model.presentOpenPanel() } label: {
                Label("Open Log…", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

struct SourceRow: View {
    @ObservedObject var source: LogSource

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.tileGradient)
                VStack(alignment: .leading, spacing: 2.5) {
                    ForEach(0..<3) { i in
                        Capsule().fill(Theme.green.opacity(0.45 + Double(i) * 0.27))
                            .frame(width: [9, 13, 7][i], height: 2.2)
                    }
                }
                .frame(width: 14, alignment: .leading)
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("\(source.url.deletingLastPathComponent().lastPathComponent) · \(source.sizeText)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if source.errorCount > 0 {
                Text(source.errorCount.formatted())
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.red.opacity(0.85)))
                    .help("\(source.errorCount) lines with errors")
            }
            StatusDot(state: source.state, paused: source.isPaused)
        }
        .padding(.vertical, 3)
    }
}

struct StatusDot: View {
    let state: LogSource.State
    let paused: Bool

    var color: Color {
        if paused { return .orange }
        switch state {
        case .following: return Theme.green
        case .loading, .waiting: return .gray
        }
    }

    var body: some View {
        Circle().fill(color.gradient).frame(width: 7, height: 7)
            .shadow(color: color.opacity(state == .following && !paused ? 0.7 : 0), radius: 3)
            .animation(.snappy, value: paused)
    }
}

// MARK: - Detail

struct LogDetail: View {
    @ObservedObject var source: LogSource
    @ObservedObject var model: TailModel

    var body: some View {
        VStack(spacing: 0) {
            LogTextView(source: source, model: model)
                .overlay(alignment: .bottomTrailing) {
                    if !source.follow {
                        Button { source.jumpToBottom() } label: {
                            Label(source.unseen > 0 ? "\(source.unseen.formatted()) new lines" : "Jump to bottom", systemImage: "arrow.down")
                                .contentTransition(.numericText())
                        }
                        .buttonStyle(PillButtonStyle([Theme.green, Theme.deep]))
                        .padding(18)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .overlay {
                    if source.visible.isEmpty && source.state != .loading {
                        emptyState.allowsHitTesting(false)
                    }
                }
                .animation(.snappy(duration: 0.2), value: source.follow)
            Divider()
            StatusBar(source: source, model: model)
        }
        .navigationTitle(source.name)
        .navigationSubtitle(source.folder)
        .toolbar { toolbar }
    }

    @ViewBuilder private var emptyState: some View {
        if model.matcher.isActive && !source.lines.isEmpty {
            ContentUnavailableView.search(text: model.filterText)
        } else if source.isPaused {
            ContentUnavailableView("Paused", systemImage: "pause.circle", description: Text("New lines wait until you resume."))
        } else {
            ContentUnavailableView("Waiting for new lines", systemImage: "text.line.last.and.arrowtriangle.forward",
                                   description: Text("Anything written to \(source.name) shows up here."))
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { source.togglePause() } label: {
                Label(source.isPaused ? "Resume" : "Pause", systemImage: source.isPaused ? "play.fill" : "pause.fill")
            }
            .help(source.isPaused ? "Resume showing new lines (⇧⌘P)" : "Hold new lines without losing them (⇧⌘P)")
            Toggle(isOn: Binding(get: { source.follow }, set: { $0 ? source.jumpToBottom() : (source.follow = false) })) {
                Label("Auto-Scroll", systemImage: "arrow.down.to.line.compact")
            }
            .help("Keep the newest line in view (⇧⌘J)")
            Toggle(isOn: $model.wrap) { Label("Wrap Lines", systemImage: "arrow.turn.down.left") }
                .help("Wrap long lines to the window width (⇧⌘L)")
            Button { source.clear() } label: { Label("Clear", systemImage: "eraser") }
                .help("Clear the view; the file is untouched (⌘K)")
        }
        ToolbarItem {
            Toggle(isOn: $model.isRegex) {
                Text(".*").font(.system(size: 13, weight: .semibold, design: .monospaced))
            }
            .help("Filter with a regular expression (⌥⌘R)")
        }
    }
}

struct StatusBar: View {
    @ObservedObject var source: LogSource
    @ObservedObject var model: TailModel

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                StatusDot(state: source.state, paused: source.isPaused)
                Text(stateText).foregroundStyle(source.isPaused ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            if source.isPaused && source.pendingCount > 0 {
                Button("Resume") { source.togglePause() }
                    .buttonStyle(.link).font(.system(size: 11, weight: .medium))
            }
            Text("\(source.lines.count.formatted()) lines").foregroundStyle(.secondary)
            if model.matcher.isActive {
                Label("\(source.visible.count(where: { !$0.isNotice }).formatted()) matching", systemImage: "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(Theme.deep)
            } else if model.matcher.isInvalid {
                Label("Not a valid regular expression", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if source.errorCount > 0 {
                Label("\(source.errorCount.formatted()) errors", systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
            }
            Spacer()
            Text(source.sizeText).foregroundStyle(.secondary)
        }
        .font(.system(size: 11)).monospacedDigit()
        .labelStyle(CompactLabel())
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
        .animation(.snappy, value: source.isPaused)
    }

    private var stateText: String {
        if source.isPaused { return source.pendingCount > 0 ? "Paused, \(source.pendingCount.formatted()) new lines held" : "Paused" }
        switch source.state {
        case .loading: return "Reading"
        case .following: return "Following"
        case .waiting: return "Waiting for the file"
        }
    }
}

struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}

// MARK: - The log text

/// The lines in a read-only NSTextView: fast with tens of thousands of lines, selectable, Find bar included.
/// Appends and trims incrementally by line id, and redraws everything only when the source asks for it.
struct LogTextView: NSViewRepresentable {
    @ObservedObject var source: LogSource
    @ObservedObject var model: TailModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LogScrollView {
        let scroll = LogScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let text = NSTextView(frame: .zero, textContainer: container)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.drawsBackground = true
        text.backgroundColor = .textBackgroundColor
        text.textContainerInset = NSSize(width: 14, height: 10)
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        scroll.documentView = text

        let coordinator = context.coordinator
        coordinator.text = text
        coordinator.scroll = scroll
        scroll.onUserScroll = { [weak coordinator] atBottom in coordinator?.userScrolled(atBottom: atBottom) }
        NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main) { [weak scroll] _ in
            MainActor.assumeIsolated { if let scroll { scroll.onUserScroll?(scroll.isAtBottom) } }
        }
        return scroll
    }

    func updateNSView(_ scroll: LogScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.source = source
        coordinator.update(lines: source.visible, key: .init(source: source.id, token: source.rebuildToken, fontSize: model.fontSize),
                           wrap: model.wrap, follow: source.follow, scrollRequest: source.scrollRequest,
                           highlighter: model.highlighter, matcher: model.matcher)
    }

    @MainActor
    final class Coordinator {
        struct Key: Equatable {
            var source: UUID
            var token: Int
            var fontSize: Double
        }

        weak var text: NSTextView?
        weak var scroll: LogScrollView?
        weak var source: LogSource?
        private var key: Key?
        private var ids: [Int] = []
        private var lengths: [Int] = []
        private var wrap: Bool?
        private var handledScroll = -1
        private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        private var bold = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)

        func userScrolled(atBottom: Bool) {
            guard let source, source.follow != atBottom else { return }
            source.follow = atBottom
        }

        func update(lines: [LogLine], key: Key, wrap: Bool, follow: Bool, scrollRequest: Int, highlighter: Highlighter, matcher: LineMatcher) {
            guard let text, let storage = text.textStorage else { return }
            var changed = false
            if key != self.key {
                self.key = key
                font = .monospacedSystemFont(ofSize: key.fontSize, weight: .regular)
                bold = .monospacedSystemFont(ofSize: key.fontSize, weight: .bold)
                let all = NSMutableAttributedString()
                lengths = []
                for line in lines {
                    let piece = attributed(line, highlighter, matcher)
                    all.append(piece)
                    lengths.append(piece.length)
                }
                storage.setAttributedString(all)
                ids = lines.map(\.id)
                changed = true
            } else {
                // Trim lines that fell off the front of the buffer.
                let first = lines.first?.id ?? Int.max
                var drop = 0, length = 0
                while drop < ids.count, ids[drop] < first { length += lengths[drop]; drop += 1 }
                storage.beginEditing()
                if drop > 0 {
                    storage.deleteCharacters(in: NSRange(location: 0, length: length))
                    ids.removeFirst(drop)
                    lengths.removeFirst(drop)
                    changed = true
                }
                // Drop lines at the end the source replaced (a finished line that was shown unfinished).
                while let lastID = ids.last, !Self.contains(lines, lastID) {
                    let length = lengths.removeLast()
                    ids.removeLast()
                    storage.deleteCharacters(in: NSRange(location: storage.length - length, length: length))
                    changed = true
                }
                // Append the lines newer than the last one shown.
                let last = ids.last ?? Int.min
                var start = lines.count
                while start > 0, lines[start - 1].id > last { start -= 1 }
                if start < lines.count {
                    let more = NSMutableAttributedString()
                    for line in lines[start...] {
                        let piece = attributed(line, highlighter, matcher)
                        more.append(piece)
                        ids.append(line.id)
                        lengths.append(piece.length)
                    }
                    storage.append(more)
                    changed = true
                }
                storage.endEditing()
            }
            applyWrap(wrap)
            scroll?.isPinned = follow
            if scrollRequest != handledScroll {
                handledScroll = scrollRequest
                scrollToBottom()
            } else if changed && follow {
                scrollToBottom()
            }
        }

        /// Binary search: the lines are ordered by id.
        static func contains(_ lines: [LogLine], _ id: Int) -> Bool {
            var low = 0, high = lines.count
            while low < high {
                let mid = (low + high) / 2
                if lines[mid].id == id { return true }
                if lines[mid].id < id { low = mid + 1 } else { high = mid }
            }
            return false
        }

        private func scrollToBottom() {
            scroll?.scrollToEnd()
        }

        private func applyWrap(_ wrap: Bool) {
            guard wrap != self.wrap, let text, let scroll, let container = text.textContainer else { return }
            self.wrap = wrap
            if wrap {
                scroll.hasHorizontalScroller = false
                text.isHorizontallyResizable = false
                text.frame.size.width = scroll.contentSize.width
                container.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
                container.widthTracksTextView = true
            } else {
                scroll.hasHorizontalScroller = true
                container.widthTracksTextView = false
                container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
                text.isHorizontallyResizable = true
            }
            text.layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: text.textStorage?.length ?? 0),
                                                 actualCharacterRange: nil)
        }

        static let noticePrefix = "● "

        private func attributed(_ line: LogLine, _ highlighter: Highlighter, _ matcher: LineMatcher) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = 1.12
            paragraph.headIndent = font.pointSize * 1.2
            if line.isNotice {
                paragraph.paragraphSpacing = font.pointSize * 0.4
                paragraph.paragraphSpacingBefore = font.pointSize * 0.4
                return NSAttributedString(string: Self.noticePrefix + line.text + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: font.pointSize - 0.5, weight: .medium),
                    .foregroundColor: NSColor.systemTeal, .paragraphStyle: paragraph,
                ])
            }
            let out = NSMutableAttributedString(string: line.text + "\n", attributes: [
                .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
            ])
            let whole = NSRange(location: 0, length: (line.text as NSString).length)
            if let stamp = Theme.timestamp.firstMatch(in: line.text, range: whole) {
                out.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: stamp.range)
            }
            for match in highlighter.matches(in: line.text) {
                out.addAttributes([.foregroundColor: match.tone.nsColor, .font: bold,
                                   .backgroundColor: match.tone.nsColor.withAlphaComponent(0.13)], range: match.range)
            }
            for range in matcher.ranges(in: line.text) {
                out.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.42), range: range)
            }
            return out
        }
    }
}

/// Tells the coordinator when the user, not the app, scrolled, so auto-scroll can turn itself off and back on.
final class LogScrollView: NSScrollView {
    var onUserScroll: ((Bool) -> Void)?

    var isAtBottom: Bool {
        guard let document = documentView else { return true }
        return contentView.bounds.maxY >= document.frame.height - 8
    }

    /// While auto-scroll is on, every layout pass (a resize, new lines, wrapping) keeps the last line in view.
    var isPinned = false

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        isPinned = isAtBottom
        onUserScroll?(isPinned)
    }

    override func layout() {
        super.layout()
        if isPinned { scrollToEnd() }
    }

    func scrollToEnd() {
        guard let text = documentView as? NSTextView, let layout = text.layoutManager, let storage = text.textStorage else { return }
        let length = storage.length
        if length > 0 { layout.ensureLayout(forCharacterRange: NSRange(location: length - 1, length: 1)) }
        let y = max(0, text.frame.height - contentView.bounds.height)
        guard abs(contentView.bounds.minY - y) > 0.5 else { return }
        contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: y))
        reflectScrolledClipView(contentView)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var model: TailModel

    var body: some View {
        Form {
            Section("Display") {
                Picker("Keep the last", selection: $model.maxLines) {
                    ForEach(TailModel.lineChoices, id: \.self) { Text("\($0.formatted()) lines").tag($0) }
                }
                Stepper(value: $model.fontSize, in: TailModel.fontRange, step: 1) {
                    LabeledContent("Text size", value: "\(Int(model.fontSize)) pt")
                }
                Toggle("Wrap long lines", isOn: $model.wrap)
            }
            Section {
                ForEach($model.rules) { $rule in
                    HStack(spacing: 10) {
                        Toggle("", isOn: $rule.isEnabled).labelsHidden().toggleStyle(.checkbox)
                        Circle().fill(rule.tone.color.gradient).frame(width: 10, height: 10)
                        TextField("Word", text: $rule.word, prompt: Text("Word"))
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                        Picker("Colour", selection: $rule.tone) {
                            ForEach(Tone.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        Button { model.rules.removeAll { $0.id == rule.id } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this rule")
                    }
                }
                HStack {
                    Button("Add Rule") { model.addRule() }
                    Spacer()
                    Button("Restore Defaults") { model.resetRules() }
                }
            } header: {
                Text("Highlight rules")
            } footer: {
                Text("Whole words in any case. The first rule that matches gives a line its colour; red lines count as errors.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
    }
}
