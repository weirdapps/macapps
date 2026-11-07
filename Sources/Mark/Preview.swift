import AppKit
import Kit
import SwiftUI

// MARK: - Environment

private struct PrintingKey: EnvironmentKey { static let defaultValue = false }
private struct BaseURLKey: EnvironmentKey { static let defaultValue: URL? = nil }
private struct TaskToggleKey: EnvironmentKey { static let defaultValue: ((Int) -> Void)? = nil }

extension EnvironmentValues {
    /// True while rendering for PDF or print: no scroll views, no hover, light colours.
    var isPrinting: Bool {
        get { self[PrintingKey.self] }
        set { self[PrintingKey.self] = newValue }
    }
    /// The folder of the document, for relative image paths.
    var documentBase: URL? {
        get { self[BaseURLKey.self] }
        set { self[BaseURLKey.self] = newValue }
    }
    var toggleTask: ((Int) -> Void)? {
        get { self[TaskToggleKey.self] }
        set { self[TaskToggleKey.self] = newValue }
    }
}

// MARK: - Preview

struct PreviewView: View {
    let blocks: [Block]

    var body: some View {
        if blocks.isEmpty {
            ContentUnavailableView {
                Label("Nothing to preview", systemImage: "text.document")
            } description: {
                Text("Type Markdown in the editor and it appears here, formatted.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                BlockStack(blocks: blocks, lazy: !Desktop.isSnapshot)
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 36)
                    .padding(.top, 28)
                    .padding(.bottom, 48)
                    .frame(maxWidth: .infinity)
                    .textSelection(.enabled)
            }
        }
    }
}

struct BlockStack: View {
    let blocks: [Block]
    var depth = 0
    var spacing: CGFloat = 14
    /// The preview's top level builds blocks as they scroll into view, so a long document opens instantly.
    var lazy = false

    var body: some View {
        Group {
            if lazy {
                LazyVStack(alignment: .leading, spacing: spacing) { rows }
            } else {
                VStack(alignment: .leading, spacing: spacing) { rows }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rows: some View {
        ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
            BlockView(block: block, depth: depth, isFirst: index == 0)
        }
    }
}

enum Typography {
    static let body: CGFloat = 14

    static func headingSize(_ level: Int) -> CGFloat {
        [28, 22, 18, 16, 14, 13][min(max(level, 1), 6) - 1]
    }

    /// Inline Markdown with code spans and links styled for the preview.
    static func inline(_ s: String, size: CGFloat = body) -> AttributedString {
        var attr = Inline.parse(s)
        for run in attr.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                attr[run.range].font = .system(size: size * 0.9, design: .monospaced)
                attr[run.range].foregroundColor = Color(nsColor: Theme.codeText)
                attr[run.range].backgroundColor = Color.primary.opacity(0.06)
            }
            if run.link != nil {
                attr[run.range].foregroundColor = Theme.accent
            }
        }
        return attr
    }
}

struct BlockView: View {
    let block: Block
    var depth = 0
    var isFirst = false
    @Environment(\.isPrinting) private var printing

    var body: some View {
        switch block {
        case .heading(let level, let text):
            VStack(alignment: .leading, spacing: 6) {
                Text(Typography.inline(text, size: Typography.headingSize(level)))
                    .font(.system(size: Typography.headingSize(level), weight: level <= 2 ? .bold : .semibold))
                    .foregroundStyle(level == 6 ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if level <= 2 { Divider() }
            }
            .padding(.top, isFirst ? 0 : (level <= 2 ? 10 : 4))
        case .paragraph(let text):
            Text(Typography.inline(text))
                .font(.system(size: Typography.body))
                .lineSpacing(3.5)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let list):
            ListBlock(list: list, depth: depth)
        case .quote(let inner):
            HStack(alignment: .top, spacing: 12) {
                Capsule().fill(Theme.gradient).frame(width: 3)
                BlockStack(blocks: inner, depth: depth, spacing: 10)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let code):
            CodeBlock(language: language, code: code)
        case .table(let table):
            if printing {
                TableBlock(table: table)
            } else {
                ScrollView(.horizontal, showsIndicators: false) { TableBlock(table: table) }
            }
        case .rule:
            Divider().padding(.vertical, 6)
        case .image(let alt, let source, let title):
            ImageBlock(alt: alt, source: source, title: title)
        }
    }
}

struct ListBlock: View {
    let list: MarkList
    let depth: Int
    @Environment(\.toggleTask) private var toggleTask

    var body: some View {
        VStack(alignment: .leading, spacing: list.tight ? 5 : 10) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { n, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(item, number: list.start + n)
                    BlockStack(blocks: item.blocks, depth: depth + 1, spacing: list.tight ? 5 : 10)
                        .foregroundStyle(item.checked == true ? .secondary : .primary)
                }
            }
        }
        .padding(.leading, 4)
    }

    @ViewBuilder
    private func marker(_ item: ListItem, number: Int) -> some View {
        if let checked = item.checked {
            Button {
                if let i = item.taskIndex { toggleTask?(i) }
            } label: {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(checked ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .help(checked ? "Mark as not done" : "Mark as done")
            .frame(width: 18)
        } else if list.ordered {
            Text("\(number).")
                .font(.system(size: Typography.body).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .trailing)
        } else {
            Text(["\u{2022}", "\u{25E6}", "\u{25AA}"][depth % 3])
                .font(.system(size: Typography.body, weight: .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 12)
        }
    }
}

struct CodeBlock: View {
    let language: String
    let code: String
    @Environment(\.isPrinting) private var printing

    var body: some View {
        let text = Text(code.isEmpty ? " " : code)
            .font(.system(size: 12.5, design: .monospaced))
            .lineSpacing(2.5)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        Group {
            if printing {
                text.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) { text.fixedSize() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        .overlay(alignment: .topTrailing) {
            if !language.isEmpty {
                Text(language.lowercased())
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, 7)
            }
        }
    }
}

struct TableBlock: View {
    let table: MarkTable

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(table.header.enumerated()), id: \.offset) { i, cell in
                    cellView(cell, column: i).fontWeight(.semibold)
                }
            }
            .background(Color.primary.opacity(0.05))
            ForEach(Array(table.rows.enumerated()), id: \.offset) { r, row in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { i, cell in cellView(cell, column: i) }
                }
                .background(r % 2 == 1 ? Color.primary.opacity(0.025) : .clear)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func alignment(_ i: Int) -> (HorizontalAlignment, Alignment) {
        switch i < table.alignments.count ? table.alignments[i] : .none {
        case .center: (.center, .center)
        case .right: (.trailing, .trailing)
        default: (.leading, .leading)
        }
    }

    private func cellView(_ s: String, column: Int) -> some View {
        Text(Typography.inline(s, size: 13))
            .font(.system(size: 13).monospacedDigit())
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: alignment(column).1)
            .gridColumnAlignment(alignment(column).0)
    }
}

struct ImageBlock: View {
    let alt: String
    let source: String
    let title: String?
    @Environment(\.documentBase) private var base

    var body: some View {
        if let image = ImageCache.image(source, base: base) {
            VStack(alignment: .leading, spacing: 6) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(image.size.width, 720), alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel(alt)
                if let title, !title.isEmpty {
                    Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .help(alt)
        } else {
            HStack(spacing: 10) {
                Image(systemName: ImageCache.isRemote(source) ? "network.slash" : "photo")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(alt.isEmpty ? "Image" : alt).font(.system(size: 13, weight: .medium))
                    Text(ImageCache.isRemote(source) ? "Remote images are not loaded: \(source)"
                         : base == nil && !source.hasPrefix("/") ? "Save the document to show \(source)" : "Not found: \(source)")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4])).foregroundStyle(.quaternary))
        }
    }
}

/// Local images, resolved against the document's folder and kept until the file changes.
@MainActor
enum ImageCache {
    private static var cache: [String: (Date, NSImage)] = [:]

    static func isRemote(_ source: String) -> Bool {
        let lower = source.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("//")
    }

    static func resolve(_ source: String, base: URL?) -> URL? {
        guard !isRemote(source) else { return nil }
        if source.lowercased().hasPrefix("file://") { return URL(string: source) }
        let path = source.removingPercentEncoding ?? source
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("~") { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        return base.map { $0.appendingPathComponent(path).standardizedFileURL }
    }

    static func image(_ source: String, base: URL?) -> NSImage? {
        guard !Desktop.isSnapshot, let url = resolve(source, base: base) else { return nil }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let hit = cache[url.path], hit.0 == date { return hit.1 }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache[url.path] = (date, image)
        return image
    }
}

// MARK: - PDF

/// Lays the preview out on A4 pages, block by block, so paragraphs are not cut between pages.
@MainActor
enum PDFExporter {
    static let page = CGRect(x: 0, y: 0, width: 595, height: 842)
    static let margin: CGFloat = 56

    static func pdf(_ blocks: [Block], baseURL: URL?) -> Data {
        let data = NSMutableData()
        var box = page
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        let width = page.width - 2 * margin
        let height = page.height - 2 * margin
        var used: CGFloat = 0
        var open = false

        func newPage() {
            if open { ctx.endPDFPage() }
            ctx.beginPDFPage(nil)
            open = true
            used = 0
        }

        for (index, block) in blocks.enumerated() {
            let gap: CGFloat = index == 0 ? 0 : 14
            let view = BlockView(block: block, isFirst: index == 0)
                .frame(width: width, alignment: .leading)
                .environment(\.isPrinting, true)
                .environment(\.documentBase, baseURL)
                .environment(\.colorScheme, .light)
                .foregroundStyle(Color.black)
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(width: width, height: nil)
            renderer.render { size, draw in
                if !open { newPage() }
                let top = used == 0 ? 0 : used + gap
                if top + size.height <= height {
                    ctx.saveGState()
                    ctx.translateBy(x: margin, y: page.height - margin - top - size.height)
                    draw(ctx)
                    ctx.restoreGState()
                    used = top + size.height
                } else if size.height <= height {
                    newPage()
                    ctx.saveGState()
                    ctx.translateBy(x: margin, y: page.height - margin - size.height)
                    draw(ctx)
                    ctx.restoreGState()
                    used = size.height
                } else {
                    // Taller than a page (a long code block): slice it across pages.
                    if used > 0 { newPage() }
                    var offset: CGFloat = 0
                    while offset < size.height {
                        if offset > 0 { newPage() }
                        ctx.saveGState()
                        ctx.clip(to: CGRect(x: margin, y: margin, width: width, height: height))
                        ctx.translateBy(x: margin, y: page.height - margin - size.height + offset)
                        draw(ctx)
                        ctx.restoreGState()
                        used = min(height, size.height - offset)
                        offset += height
                    }
                }
            }
        }
        if !open { newPage() }
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }
}
