import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Document

extension UTType {
    /// Markdown, as Finder and most editors declare it.
    static let markdownText = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

struct MarkDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.markdownText, .plainText]
    static let writableContentTypes: [UTType] = [.markdownText, .plainText]

    var text: String

    init(text: String = "") { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        text = Self.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }

    /// UTF-8 first (dropping a byte order mark), then the legacy encodings old notes were saved in.
    static func decode(_ data: Data) -> String {
        var data = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        if let s = String(data: data, encoding: .utf8) { return s }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) { return s }
        return String(data: data, encoding: .macOSRoman) ?? String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Blocks

enum ColumnAlignment: Equatable { case none, left, center, right }

struct MarkTable: Equatable {
    var alignments: [ColumnAlignment]
    var header: [String]
    var rows: [[String]]
}

struct ListItem: Equatable {
    /// nil for a plain item, otherwise whether the task box is ticked.
    var checked: Bool?
    /// Position among all task items of the document, in source order, so the preview can tick the right box.
    var taskIndex: Int?
    var blocks: [Block]
}

struct MarkList: Equatable {
    var ordered: Bool
    var start: Int
    var tight: Bool
    var items: [ListItem]
}

enum Block: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(MarkList)
    case quote([Block])
    case code(language: String, code: String)
    case table(MarkTable)
    case rule
    case image(alt: String, source: String, title: String?)
}

// MARK: - Parser

/// A small block parser for the Markdown people actually write: CommonMark blocks plus GitHub tables and task lists.
/// Inline syntax (emphasis, code spans, links) is left to Foundation's `AttributedString(markdown:)`.
enum MarkdownParser {
    static func parse(_ text: String) -> [Block] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map(expandLeadingTabs)
        var blocks = parseLines(lines)
        var counter = 0
        numberTasks(&blocks, &counter)
        return blocks
    }

    private static func numberTasks(_ blocks: inout [Block], _ counter: inout Int) {
        for i in blocks.indices {
            switch blocks[i] {
            case .list(var list):
                for j in list.items.indices {
                    if list.items[j].checked != nil { list.items[j].taskIndex = counter; counter += 1 }
                    numberTasks(&list.items[j].blocks, &counter)
                }
                blocks[i] = .list(list)
            case .quote(var inner):
                numberTasks(&inner, &counter)
                blocks[i] = .quote(inner)
            default: break
            }
        }
    }

    /// Quotes and lists nest at most this deep; anything deeper is shown as text, so a line of a thousand `>` cannot exhaust the stack.
    static let maxDepth = 16

    static func parseLines(_ lines: [String], depth: Int = 0) -> [Block] {
        if depth > maxDepth {
            let text = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return text.isEmpty ? [] : [.paragraph(text.joined(separator: " "))]
        }
        var blocks: [Block] = []
        var para: [String] = []
        var i = 0

        func flush() {
            guard !para.isEmpty else { return }
            blocks.append(paragraph(para))
            para = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = leadingSpaces(line)

            if trimmed.isEmpty { flush(); i += 1; continue }

            // Setext heading: a paragraph underlined with === or ---.
            if !para.isEmpty, indent < 4, let level = setextLevel(trimmed) {
                blocks.append(.heading(level: level, text: para.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")))
                para = []
                i += 1
                continue
            }

            // Indented code, only where it cannot be a paragraph continuation.
            if indent >= 4, para.isEmpty {
                var code: [String] = []
                while i < lines.count, leadingSpaces(lines[i]) >= 4 || lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    code.append(lines[i].trimmingCharacters(in: .whitespaces).isEmpty ? "" : String(lines[i].dropFirst(4)))
                    i += 1
                }
                while code.last == "" { code.removeLast() }
                blocks.append(.code(language: "", code: code.joined(separator: "\n")))
                continue
            }

            if indent < 4, let fence = fenceOpening(trimmed) {
                flush()
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(fence.marker), t.allSatisfy({ $0 == fence.marker.first! }) { i += 1; break }
                    code.append(String(lines[i].dropFirst(min(indent, leadingSpaces(lines[i])))))
                    i += 1
                }
                blocks.append(.code(language: fence.info, code: code.joined(separator: "\n")))
                continue
            }

            if indent < 4, let heading = atxHeading(trimmed) {
                flush()
                blocks.append(heading)
                i += 1
                continue
            }

            if indent < 4, isRule(trimmed) {
                flush()
                blocks.append(.rule)
                i += 1
                continue
            }

            if indent < 4, trimmed.hasPrefix(">") {
                flush()
                var inner: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(">") {
                        var rest = t.dropFirst()
                        if rest.first == " " { rest = rest.dropFirst() }
                        inner.append(String(rest))
                    } else if !t.isEmpty, let last = inner.last, !last.isEmpty, isLazyTarget(last), !startsBlock(lines[i]) {
                        inner.append(t) // Lazy continuation of a quoted paragraph.
                    } else {
                        break
                    }
                    i += 1
                }
                blocks.append(.quote(parseLines(inner, depth: depth + 1)))
                continue
            }

            if let marker = listMarker(line), marker.indent < 4, para.isEmpty || !marker.ordered || marker.number == 1 {
                flush()
                blocks.append(.list(parseList(lines, &i, first: marker, depth: depth + 1)))
                continue
            }

            if para.isEmpty, indent < 4, line.contains("|"), i + 1 < lines.count, let alignments = tableSeparator(lines[i + 1]) {
                let header = cells(line)
                if header.count == alignments.count {
                    i += 2
                    var rows: [[String]] = []
                    while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                        var row = cells(lines[i])
                        if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
                        rows.append(Array(row.prefix(header.count)))
                        i += 1
                    }
                    blocks.append(.table(MarkTable(alignments: alignments, header: header, rows: rows)))
                    continue
                }
            }

            para.append(line)
            i += 1
        }
        flush()
        return blocks
    }

    // MARK: Lists

    struct Marker: Equatable {
        var ordered: Bool
        var number: Int
        var symbol: Character // The bullet, or the delimiter after the number.
        var indent: Int
        var contentIndent: Int
        var rest: String
    }

    static func listMarker(_ line: String) -> Marker? {
        let indent = leadingSpaces(line)
        let body = Array(line.dropFirst(indent))
        guard let first = body.first else { return nil }
        var markerLength = 0
        var ordered = false, number = 0, symbol = first
        if "-*+".contains(first) {
            markerLength = 1
        } else if first.isASCII, first.isNumber {
            var digits = ""
            for c in body { if c.isASCII, c.isNumber { digits.append(c) } else { break } }
            guard digits.count <= 9, digits.count < body.count, ".)".contains(body[digits.count]) else { return nil }
            ordered = true
            number = Int(digits) ?? 1
            symbol = body[digits.count]
            markerLength = digits.count + 1
        } else {
            return nil
        }
        let after = body.dropFirst(markerLength)
        if after.isEmpty { return Marker(ordered: ordered, number: number, symbol: symbol, indent: indent, contentIndent: indent + markerLength + 1, rest: "") }
        guard after.first == " " else { return nil }
        let spaces = after.prefix { $0 == " " }.count
        let gap = spaces > 4 ? 1 : spaces
        let rest = String(after.dropFirst(gap))
        return Marker(ordered: ordered, number: number, symbol: symbol, indent: indent, contentIndent: indent + markerLength + gap, rest: rest)
    }

    private static func parseList(_ lines: [String], _ i: inout Int, first: Marker, depth: Int) -> MarkList {
        var items: [ListItem] = []
        var tight = true
        var marker: Marker? = first

        while let m = marker {
            var body = [m.rest]
            var sawBlank = false
            i += 1
            while i < lines.count {
                let line = lines[i]
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { body.append(""); sawBlank = true; i += 1; continue }
                let indent = leadingSpaces(line)
                if indent >= m.contentIndent {
                    body.append(String(line.dropFirst(m.contentIndent)))
                    if sawBlank { tight = false; sawBlank = false }
                    i += 1
                } else if !sawBlank, !startsBlock(line) {
                    body.append(t) // Lazy continuation line.
                    i += 1
                } else {
                    break
                }
            }
            while body.last == "" { body.removeLast() }

            var checked: Bool?
            if let head = body.first, head.count >= 3, head.hasPrefix("["), ["[ ]", "[x]", "[X]"].contains(String(head.prefix(3))),
               head.count == 3 || head.dropFirst(3).first == " " {
                checked = head.prefix(3) != "[ ]"
                body[0] = String(head.dropFirst(3).drop { $0 == " " })
            }
            items.append(ListItem(checked: checked, taskIndex: nil, blocks: parseLines(body, depth: depth)))

            marker = nil
            if i < lines.count, let next = listMarker(lines[i]), next.ordered == first.ordered, next.symbol == first.symbol,
               next.indent < first.contentIndent, !isRule(lines[i].trimmingCharacters(in: .whitespaces)) {
                if sawBlank { tight = false }
                marker = next
            }
        }
        return MarkList(ordered: first.ordered, start: first.number, tight: tight, items: items)
    }

    // MARK: Line tests

    static func leadingSpaces(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    private static func expandLeadingTabs(_ line: String) -> String {
        guard line.hasPrefix("\t") || line.hasPrefix(" ") else { return line }
        var out = "", column = 0
        var rest = Substring(line)
        while let c = rest.first, c == " " || c == "\t" {
            let width = c == "\t" ? 4 - column % 4 : 1
            out += String(repeating: " ", count: width)
            column += width
            rest = rest.dropFirst()
        }
        return out + rest
    }

    /// True for lines that begin a block of their own and so end a lazy paragraph continuation.
    static func startsBlock(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return atxHeading(t) != nil || isRule(t) || fenceOpening(t) != nil || t.hasPrefix(">") || listMarker(line) != nil
    }

    /// A line a lazy continuation can extend: paragraph text, not a heading, fence or rule.
    private static func isLazyTarget(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return atxHeading(t) == nil && !isRule(t) && fenceOpening(t) == nil && leadingSpaces(line) < 4
    }

    static func atxHeading(_ t: String) -> Block? {
        let hashes = t.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = t.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Optional closing hashes.
        if let range = text.range(of: "\\s+#+$", options: .regularExpression) { text.removeSubrange(range) }
        else if text.allSatisfy({ $0 == "#" }) { text = "" }
        return .heading(level: hashes, text: text)
    }

    static func isRule(_ t: String) -> Bool {
        let chars = t.filter { $0 != " " && $0 != "\t" }
        guard chars.count >= 3, let c = chars.first, "-*_".contains(c) else { return false }
        return chars.allSatisfy { $0 == c }
    }

    private static func setextLevel(_ t: String) -> Int? {
        if t.count >= 1, t.allSatisfy({ $0 == "=" }) { return 1 }
        if t.count >= 2, t.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    static func fenceOpening(_ t: String) -> (marker: String, info: String)? {
        for c in ["`", "~"] {
            let run = t.prefix { String($0) == c }.count
            if run >= 3 {
                let info = t.dropFirst(run).trimmingCharacters(in: .whitespaces)
                if c == "`", info.contains("`") { return nil }
                return (String(repeating: c, count: run), info.split(separator: " ").first.map(String.init) ?? "")
            }
        }
        return nil
    }

    static func tableSeparator(_ line: String) -> [ColumnAlignment]? {
        let parts = cells(line)
        guard !parts.isEmpty, line.contains("-") else { return nil }
        var result: [ColumnAlignment] = []
        for p in parts {
            let core = p.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
            switch (p.hasPrefix(":"), p.hasSuffix(":")) {
            case (true, true): result.append(.center)
            case (true, false): result.append(.left)
            case (false, true): result.append(.right)
            default: result.append(.none)
            }
        }
        return result
    }

    /// Splits a table row on unescaped pipes, ignoring the optional outer pipes.
    static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = [], current = "", escaped = false, inCode = false
        for c in t {
            if escaped { current.append(c == "|" ? "|" : "\\\(c)"); escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == "`" { inCode.toggle() }
            if c == "|", !inCode { cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(c)
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func paragraph(_ lines: [String]) -> Block {
        if lines.count == 1, let image = standaloneImage(lines[0].trimmingCharacters(in: .whitespaces)) { return image }
        var text = ""
        for (n, raw) in lines.enumerated() {
            var line = raw.drop { $0 == " " }
            let last = n == lines.count - 1
            if last { text += line.trimmingCharacters(in: .whitespaces); break }
            if line.hasSuffix("  ") {
                text += line.trimmingCharacters(in: .whitespaces) + "\n"
            } else if line.hasSuffix("\\") {
                line.removeLast()
                text += line + "\n"
            } else {
                text += line.trimmingCharacters(in: .whitespaces) + " "
            }
        }
        return .paragraph(text)
    }

    static func standaloneImage(_ t: String) -> Block? {
        guard t.hasPrefix("!["), t.hasSuffix(")"), let close = t.range(of: "](") else { return nil }
        let alt = String(t[t.index(t.startIndex, offsetBy: 2)..<close.lowerBound])
        guard !alt.contains("]") else { return nil }
        var target = String(t[close.upperBound..<t.index(before: t.endIndex)]).trimmingCharacters(in: .whitespaces)
        var title: String?
        if target.hasSuffix("\""), let q = target.range(of: " \""), q.upperBound < target.endIndex {
            title = String(target[q.upperBound..<target.index(before: target.endIndex)])
            target = String(target[..<q.lowerBound])
        }
        if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
        guard !target.isEmpty else { return nil }
        return .image(alt: alt, source: target, title: title)
    }
}

// MARK: - Inline

enum Inline {
    /// Inline Markdown as an attributed string, keeping hard line breaks. Falls back to the literal text.
    static func parse(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }

    /// The words a reader sees, without markup.
    static func plain(_ s: String) -> String { String(parse(s).characters) }
}

// MARK: - Statistics

struct TextStats: Equatable {
    var words = 0
    var characters = 0
    var minutes: Int { words == 0 ? 0 : max(1, Int((Double(words) / 230).rounded(.up))) }

    init(words: Int = 0, characters: Int = 0) {
        self.words = words
        self.characters = characters
    }

    init(source: String, blocks: [Block]) {
        characters = source.count
        words = Self.countWords(Self.plainText(blocks))
    }

    static func countWords(_ s: String) -> Int {
        var n = 0
        s.enumerateSubstrings(in: s.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in n += 1 }
        return n
    }

    static func plainText(_ blocks: [Block]) -> String {
        blocks.map { block -> String in
            switch block {
            case .heading(_, let t), .paragraph(let t): Inline.plain(t)
            case .list(let list): list.items.map { plainText($0.blocks) }.joined(separator: "\n")
            case .quote(let inner): plainText(inner)
            case .code(_, let code): code
            case .table(let table): ([table.header] + table.rows).map { $0.map(Inline.plain).joined(separator: " ") }.joined(separator: "\n")
            case .rule: ""
            case .image(let alt, _, _): alt
            }
        }.joined(separator: "\n")
    }
}

// MARK: - HTML

enum HTMLExporter {
    static func document(_ blocks: [Block], title: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="Mark">
        <title>\(escape(title))</title>
        <style>
        \(css)
        </style>
        </head>
        <body>
        <article>
        \(body(blocks))</article>
        </body>
        </html>

        """
    }

    static func body(_ blocks: [Block], tight: Bool = false) -> String {
        blocks.map { html($0, tight: tight) }.joined()
    }

    private static func html(_ block: Block, tight: Bool) -> String {
        switch block {
        case .heading(let level, let text):
            return "<h\(level)>\(inline(text))</h\(level)>\n"
        case .paragraph(let text):
            return tight ? inline(text) + "\n" : "<p>\(inline(text))</p>\n"
        case .list(let list):
            let open = list.ordered ? (list.start == 1 ? "<ol>" : "<ol start=\"\(list.start)\">") : "<ul>"
            var out = open + "\n"
            for item in list.items {
                var content = body(item.blocks, tight: list.tight)
                if content.hasSuffix("\n") { content.removeLast() }
                if let checked = item.checked {
                    out += "<li class=\"task\"><input type=\"checkbox\" disabled\(checked ? " checked" : "")> \(content)</li>\n"
                } else {
                    out += "<li>\(content)</li>\n"
                }
            }
            return out + (list.ordered ? "</ol>\n" : "</ul>\n")
        case .quote(let inner):
            return "<blockquote>\n\(body(inner))</blockquote>\n"
        case .code(let language, let code):
            let cls = language.isEmpty ? "" : " class=\"language-\(escape(language))\""
            return "<pre><code\(cls)>\(escape(code))\n</code></pre>\n"
        case .table(let table):
            func style(_ i: Int) -> String {
                switch i < table.alignments.count ? table.alignments[i] : .none {
                case .none: ""
                case .left: " style=\"text-align:left\""
                case .center: " style=\"text-align:center\""
                case .right: " style=\"text-align:right\""
                }
            }
            var out = "<table>\n<thead>\n<tr>"
            for (i, h) in table.header.enumerated() { out += "<th\(style(i))>\(inline(h))</th>" }
            out += "</tr>\n</thead>\n<tbody>\n"
            for row in table.rows {
                out += "<tr>"
                for (i, c) in row.enumerated() { out += "<td\(style(i))>\(inline(c))</td>" }
                out += "</tr>\n"
            }
            return out + "</tbody>\n</table>\n"
        case .rule:
            return "<hr>\n"
        case .image(let alt, let source, let title):
            let t = title.map { " title=\"\(escape($0))\"" } ?? ""
            guard let safe = safeURL(source) else { return "<p>\(escape(alt))</p>\n" }
            return "<p><img src=\"\(escape(safe))\" alt=\"\(escape(alt))\"\(t)></p>\n"
        }
    }

    static func inline(_ s: String) -> String {
        let attr = Inline.parse(s)
        var out = ""
        for (link, range) in attr.runs[\.link] {
            var inner = ""
            for run in attr[range].runs {
                let text = String(attr[run.range].characters)
                if let image = run.imageURL {
                    if let safe = safeURL(image.relativeString) {
                        inner += "<img src=\"\(escape(safe))\" alt=\"\(escape(text))\">"
                    } else {
                        inner += escape(text)
                    }
                    continue
                }
                var piece = escape(text).replacingOccurrences(of: "\n", with: "<br>\n")
                let intent = run.inlinePresentationIntent ?? []
                if intent.contains(.code) { piece = "<code>\(piece)</code>" }
                if intent.contains(.strikethrough) { piece = "<del>\(piece)</del>" }
                if intent.contains(.emphasized) { piece = "<em>\(piece)</em>" }
                if intent.contains(.stronglyEmphasized) { piece = "<strong>\(piece)</strong>" }
                inner += piece
            }
            out += link.flatMap { safeURL($0.relativeString) }.map { "<a href=\"\(escape($0))\">\(inner)</a>" } ?? inner
        }
        return out
    }

    /// Links and images in exported HTML keep only web, mail and relative addresses, so a file opened in a browser
    /// cannot run script through a javascript:, vbscript: or data: link.
    static func safeURL(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased().filter { !$0.isWhitespace && !$0.isNewline && $0 != "\u{0}" }
        guard let colon = lowered.firstIndex(of: ":") else { return trimmed }
        let scheme = lowered[..<colon]
        // A colon after a slash, a question mark or a hash is part of a relative path, not a scheme.
        if scheme.contains(where: { "/?#".contains($0) }) { return trimmed }
        return ["http", "https", "mailto"].contains(String(scheme)) ? trimmed : nil
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }

    static let css = """
    :root { color-scheme: light dark; --accent: #3D67E0; --muted: #6b7280; --line: #e5e7eb; --code: #f4f5f7; }
    @media (prefers-color-scheme: dark) { :root { --accent: #8AA9FF; --muted: #9ca3af; --line: #374151; --code: #1f2227; } body { background: #16181c; color: #e6e7ea; } }
    body { margin: 0; font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color: #1f2328; }
    article { max-width: 760px; margin: 0 auto; padding: 48px 28px 72px; }
    h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.6em 0 0.6em; }
    h1 { font-size: 2em; padding-bottom: 0.3em; border-bottom: 1px solid var(--line); }
    h2 { font-size: 1.5em; padding-bottom: 0.3em; border-bottom: 1px solid var(--line); }
    h3 { font-size: 1.25em; } h6 { color: var(--muted); }
    article > :first-child { margin-top: 0; }
    a { color: var(--accent); text-decoration: none; } a:hover { text-decoration: underline; }
    code, pre { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.88em; }
    code { background: var(--code); padding: 0.15em 0.4em; border-radius: 5px; }
    pre { background: var(--code); padding: 14px 16px; border-radius: 10px; overflow-x: auto; line-height: 1.45; }
    pre code { background: none; padding: 0; font-size: 1em; }
    blockquote { margin: 1em 0; padding: 0 1em; color: var(--muted); border-left: 3px solid var(--accent); }
    table { border-collapse: collapse; margin: 1em 0; display: block; overflow-x: auto; }
    th, td { border: 1px solid var(--line); padding: 6px 13px; }
    th { background: var(--code); }
    hr { border: 0; border-top: 1px solid var(--line); margin: 2em 0; }
    img { max-width: 100%; border-radius: 8px; }
    li.task { list-style: none; margin-left: -1.4em; }
    li.task input { margin-right: 0.4em; accent-color: var(--accent); }
    """
}

// MARK: - Editing

/// One undoable change to the source: replace `range` with `replacement`, then select `selection`.
struct TextEdit: Equatable {
    var range: NSRange
    var replacement: String
    var selection: NSRange

    func apply(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }
}

enum Formatting {
    /// Wraps the selection in `marker`, or unwraps it when it is already wrapped.
    static func toggleWrap(_ text: String, _ sel: NSRange, marker: String) -> TextEdit {
        let ns = text as NSString
        let m = (marker as NSString).length
        if sel.location >= m, sel.upperBound + m <= ns.length,
           ns.substring(with: NSRange(location: sel.location - m, length: m)) == marker,
           ns.substring(with: NSRange(location: sel.upperBound, length: m)) == marker {
            let inner = ns.substring(with: sel)
            return TextEdit(range: NSRange(location: sel.location - m, length: sel.length + 2 * m), replacement: inner,
                            selection: NSRange(location: sel.location - m, length: sel.length))
        }
        let selected = ns.substring(with: sel)
        if sel.length >= 2 * m, selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let inner = (selected as NSString).substring(with: NSRange(location: m, length: sel.length - 2 * m))
            return TextEdit(range: sel, replacement: inner, selection: NSRange(location: sel.location, length: sel.length - 2 * m))
        }
        return TextEdit(range: sel, replacement: marker + selected + marker, selection: NSRange(location: sel.location + m, length: sel.length))
    }

    /// Turns the selection into a link, leaving the part still to type selected.
    static func link(_ text: String, _ sel: NSRange) -> TextEdit {
        let selected = (text as NSString).substring(with: sel)
        if selected.hasPrefix("http://") || selected.hasPrefix("https://") || selected.hasPrefix("mailto:") {
            return TextEdit(range: sel, replacement: "[](\(selected))", selection: NSRange(location: sel.location + 1, length: 0))
        }
        let replacement = "[\(selected)](https://)"
        let urlStart = sel.location + 1 + (selected as NSString).length + 2
        return TextEdit(range: sel, replacement: replacement, selection: NSRange(location: urlStart, length: 8))
    }

    /// Sets the heading level of the line holding the cursor; 0 makes it body text, the same level again toggles it off.
    static func heading(_ text: String, _ sel: NSRange, level: Int) -> TextEdit {
        let ns = text as NSString
        let line = ns.lineRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
        let content = ns.substring(with: line)
        let hashes = content.prefix { $0 == "#" }.count
        var existing = 0
        var current = 0
        if (1...6).contains(hashes), content.dropFirst(hashes).first.map({ $0 == " " || $0 == "\n" }) ?? true {
            current = hashes
            existing = hashes + content.dropFirst(hashes).prefix { $0 == " " }.count
        }
        let target = current == level ? 0 : level
        let prefix = target == 0 ? "" : String(repeating: "#", count: target) + " "
        let added = (prefix as NSString).length
        // Points inside the old prefix land after the new one; points after it shift with the line.
        func map(_ p: Int) -> Int {
            p < line.location ? p : p < line.location + existing ? line.location + added : p + added - existing
        }
        let start = map(sel.location), end = max(start, map(sel.upperBound))
        return TextEdit(range: NSRange(location: line.location, length: existing), replacement: prefix,
                        selection: NSRange(location: start, length: end - start))
    }

    /// Ticks or unticks the `index`th task box of the document, skipping fenced code.
    static func toggleTask(_ text: String, index: Int) -> TextEdit? {
        let ns = text as NSString
        let regex = try! NSRegularExpression(pattern: "^[ \\t]*(?:>[ \\t]?)*(?:[ \\t]*)(?:[-*+]|\\d{1,9}[.)])[ \\t]+\\[([ xX])\\](?=[ \\t]|$)")
        var count = 0
        var fence: String?
        var location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let content = ns.substring(with: line)
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if let f = fence {
                if trimmed.hasPrefix(f), trimmed.allSatisfy({ $0 == f.first! }) { fence = nil }
            } else if let open = MarkdownParser.fenceOpening(trimmed) {
                fence = open.marker
            } else if let match = regex.firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length)) {
                if count == index {
                    let box = match.range(at: 1)
                    let ticked = (content as NSString).substring(with: box) != " "
                    let range = NSRange(location: line.location + box.location, length: 1)
                    return TextEdit(range: range, replacement: ticked ? " " : "x", selection: NSRange(location: range.location, length: 0))
                }
                count += 1
            }
            location = line.upperBound
        }
        return nil
    }
}

// MARK: - Demo

enum Demo {
    static let text = """
    # Launch plan

    Ship **Orbit 2.0** by *Friday*. Everything is merged into `main`, and the [roadmap](https://example.com/roadmap) lists what slips to 2.1.

    ## This week

    - [x] Freeze the feature list
    - [x] Record the release video
    - [ ] Write the App Store notes
    - [ ] Send the press kit to ~~eight~~ twelve sites

    ## Numbers

    | Metric | Beta | Goal |
    |:--|--:|--:|
    | Crash-free sessions | 99.2% | 99.8% |
    | Daily users | 4,180 | 6,000 |
    | Rating | 4.6 | 4.8 |

    > Make it small, make it fast, make it feel like it belongs.

    ```swift
    let release = Release(version: "2.0")
    try await release.ship()
    ```

    """
}
