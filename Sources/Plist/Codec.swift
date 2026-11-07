import Foundation

/// How a document is stored on disk.
enum FileFormat: String, CaseIterable, Identifiable, Sendable {
    case xml, binary, json

    var id: String { rawValue }

    var name: String {
        switch self {
        case .xml: "XML"
        case .binary: "Binary"
        case .json: "JSON"
        }
    }

    var longName: String {
        switch self {
        case .xml: "XML property list"
        case .binary: "Binary property list"
        case .json: "JSON"
        }
    }

    var fileExtension: String { self == .json ? "json" : "plist" }
}

struct CodecError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Reading and writing XML and binary property lists and JSON, keeping key order wherever the format has one.
enum Codec {
    /// Parses a file and tells which format it was in. XML and JSON keep their key order; binary and old-style
    /// property lists come back with sorted keys, as Xcode shows them.
    static func read(_ data: Data) throws -> (PNode, FileFormat) {
        let head = data.prefix(64)
        if head.starts(with: Array("bplist".utf8)) {
            return (try foundationPlist(data), .binary)
        }
        let firstByte = data.first { !Set(Array(" \t\r\n".utf8) + [0xEF, 0xBB, 0xBF]).contains($0) }
        if firstByte == UInt8(ascii: "<") { return (try parseXML(data), .xml) }
        if firstByte == UInt8(ascii: "{") || firstByte == UInt8(ascii: "[") || firstByte == UInt8(ascii: "\"") {
            if let node = try? parseJSON(data) { return (node, .json) }
        }
        if let node = try? parseJSON(data) { return (node, .json) }
        // Old-style OpenStep plists: readable, saved as XML.
        if let node = try? foundationPlist(data) { return (node, .xml) }
        throw CodecError(message: "This file is not a property list or JSON.")
    }

    static func encode(_ root: PNode, as format: FileFormat) throws -> Data {
        switch format {
        case .xml: Data(xml(root).utf8)
        case .json: Data(json(root).utf8)
        case .binary: try binary(root)
        }
    }

    // MARK: Foundation bridge

    private static func foundationPlist(_ data: Data) throws -> PNode {
        do {
            let any = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            return PNode(key: "Root", value: value(fromFoundation: any))
        } catch {
            throw CodecError(message: "The property list could not be read.")
        }
    }

    static func value(fromFoundation any: Any) -> PValue {
        switch any {
        case let s as String: return .string(s)
        case let d as Date: return .date(d)
        case let d as Data: return .data(d)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .boolean(n.boolValue) }
            if CFNumberIsFloatType(n) { return .real(n.doubleValue) }
            return .integer(n.intValue)
        case let a as [Any]:
            return .array(a.map { PNode(key: "", value: value(fromFoundation: $0)) })
        case let d as [String: Any]:
            let keys = d.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return .dictionary(keys.map { PNode(key: $0, value: value(fromFoundation: d[$0]!)) })
        default:
            return .null
        }
    }

    /// Foundation objects for `PropertyListSerialization`; null entries have no plist form and are left out.
    static func foundation(_ value: PValue) -> Any? {
        switch value {
        case .dictionary(let c):
            var d: [String: Any] = [:]
            for n in c { if let v = foundation(n.value) { d[n.key] = v } }
            return d
        case .array(let c): return c.compactMap { foundation($0.value) }
        case .string(let s): return s
        case .integer(let i): return i
        case .real(let r): return r
        case .boolean(let b): return b
        case .date(let d): return d
        case .data(let d): return d
        case .null: return nil
        }
    }

    static func binary(_ root: PNode) throws -> Data {
        let object = foundation(root.value) ?? [String: Any]()
        do {
            return try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        } catch {
            throw CodecError(message: "The binary property list could not be written.")
        }
    }

    // MARK: XML

    static let xmlHeader = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">

        """

    /// An XML property list laid out the way Apple's own writer does, in the document's key order.
    static func xml(_ root: PNode) -> String {
        var out = xmlHeader
        writeXML(root.value == .null ? .dictionary([]) : root.value, depth: 0, into: &out)
        out += "</plist>\n"
        return out
    }

    private static func writeXML(_ value: PValue, depth: Int, into out: inout String) {
        let pad = String(repeating: "\t", count: depth)
        switch value {
        case .dictionary(let c):
            let items = c.filter { $0.value != .null }
            if items.isEmpty { out += pad + "<dict/>\n"; return }
            out += pad + "<dict>\n"
            for n in items {
                out += pad + "\t<key>" + escapeXML(n.key) + "</key>\n"
                writeXML(n.value, depth: depth + 1, into: &out)
            }
            out += pad + "</dict>\n"
        case .array(let c):
            let items = c.filter { $0.value != .null }
            if items.isEmpty { out += pad + "<array/>\n"; return }
            out += pad + "<array>\n"
            for n in items { writeXML(n.value, depth: depth + 1, into: &out) }
            out += pad + "</array>\n"
        case .string(let s): out += pad + "<string>" + escapeXML(s) + "</string>\n"
        case .integer(let i): out += pad + "<integer>\(i)</integer>\n"
        case .real(let r): out += pad + "<real>" + Format.real(r) + "</real>\n"
        case .boolean(let b): out += pad + (b ? "<true/>\n" : "<false/>\n")
        case .date(let d): out += pad + "<date>" + Format.iso(d) + "</date>\n"
        case .data(let d):
            let b64 = d.base64EncodedString()
            if b64.isEmpty { out += pad + "<data>\n" + pad + "</data>\n"; return }
            out += pad + "<data>\n"
            var start = b64.startIndex
            while start < b64.endIndex {
                let end = b64.index(start, offsetBy: 68, limitedBy: b64.endIndex) ?? b64.endIndex
                out += pad + b64[start..<end] + "\n"
                start = end
            }
            out += pad + "</data>\n"
        case .null: break
        }
    }

    static func escapeXML(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.append(c)
            }
        }
        return out
    }

    static func parseXML(_ data: Data) throws -> PNode {
        let reader = XMLPlistReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        let ok = parser.parse()
        if let message = reader.error { throw CodecError(message: message) }
        guard ok, let value = reader.result else {
            let line = parser.lineNumber
            throw CodecError(message: "The XML is not valid (line \(line)): \(parser.parserError?.localizedDescription ?? "unknown error").")
        }
        return PNode(key: "Root", value: value)
    }

    // MARK: JSON

    /// Pretty printed JSON in the document's key order. Dates become ISO 8601 strings and data base64 strings.
    static func json(_ root: PNode) -> String {
        var out = ""
        writeJSON(root.value, depth: 0, into: &out)
        return out + "\n"
    }

    private static func writeJSON(_ value: PValue, depth: Int, into out: inout String) {
        let pad = String(repeating: "  ", count: depth + 1), close = String(repeating: "  ", count: depth)
        switch value {
        case .dictionary(let c):
            if c.isEmpty { out += "{}"; return }
            out += "{\n"
            for (i, n) in c.enumerated() {
                out += pad + quoteJSON(n.key) + ": "
                writeJSON(n.value, depth: depth + 1, into: &out)
                out += i == c.count - 1 ? "\n" : ",\n"
            }
            out += close + "}"
        case .array(let c):
            if c.isEmpty { out += "[]"; return }
            out += "[\n"
            for (i, n) in c.enumerated() {
                out += pad
                writeJSON(n.value, depth: depth + 1, into: &out)
                out += i == c.count - 1 ? "\n" : ",\n"
            }
            out += close + "]"
        case .string(let s): out += quoteJSON(s)
        case .integer(let i): out += String(i)
        case .real(let r): out += r.isFinite ? "\(r)" : "null"
        case .boolean(let b): out += b ? "true" : "false"
        case .date(let d): out += quoteJSON(Format.iso(d))
        case .data(let d): out += quoteJSON(d.base64EncodedString())
        case .null: out += "null"
        }
    }

    static func quoteJSON(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    static func parseJSON(_ data: Data) throws -> PNode {
        var reader = JSONReader(bytes: Array(data))
        return PNode(key: "Root", value: try reader.document())
    }
}

// MARK: - XML reader

/// Builds the tree from XMLParser events, keeping dictionary order.
private final class XMLPlistReader: NSObject, XMLParserDelegate {
    private enum Frame {
        case dictionary([PNode], key: String?)
        case array([PNode])
    }

    private var stack: [Frame] = []
    private var text = ""
    private var sawPlist = false
    var result: PValue?
    var error: String?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch name {
        case "plist": sawPlist = true
        case "dict": stack.append(.dictionary([], key: nil))
        case "array": stack.append(.array([]))
        case "key", "string", "integer", "real", "date", "data": text = ""
        case "true", "false": break
        default: fail(parser, "Unknown element <\(name)> on line \(parser.lineNumber).")
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA block: Data) { text += String(decoding: block, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "plist":
            if result == nil && error == nil { result = .dictionary([]) }
        case "key":
            guard case .dictionary(let items, nil) = stack.last else { return fail(parser, "A key outside a dictionary on line \(parser.lineNumber).") }
            stack[stack.count - 1] = .dictionary(items, key: text)
        case "dict":
            guard case .dictionary(let items, let key) = stack.popLast() else { return fail(parser, "Unbalanced <dict>.") }
            if key != nil { return fail(parser, "A key without a value on line \(parser.lineNumber).") }
            emit(.dictionary(items), parser)
        case "array":
            guard case .array(let items) = stack.popLast() else { return fail(parser, "Unbalanced <array>.") }
            emit(.array(items), parser)
        case "string": emit(.string(text), parser)
        case "integer":
            if let i = Int(trimmed) { emit(.integer(i), parser) }
            else if let u = UInt64(trimmed) { emit(.real(Double(u)), parser) }
            else { fail(parser, "\"\(trimmed)\" is not an integer (line \(parser.lineNumber)).") }
        case "real":
            if let v = Format.number(trimmed, preferReal: true) { emit(v, parser) }
            else { fail(parser, "\"\(trimmed)\" is not a number (line \(parser.lineNumber)).") }
        case "true": emit(.boolean(true), parser)
        case "false": emit(.boolean(false), parser)
        case "date":
            if let d = Format.date(trimmed) { emit(.date(d), parser) }
            else { fail(parser, "\"\(trimmed)\" is not a date (line \(parser.lineNumber)).") }
        case "data":
            if let d = Data(base64Encoded: trimmed.filter { !$0.isWhitespace }) { emit(.data(d), parser) }
            else { fail(parser, "Invalid base64 data on line \(parser.lineNumber).") }
        default: break
        }
    }

    private func emit(_ value: PValue, _ parser: XMLParser) {
        guard let top = stack.last else {
            if result == nil { result = value } else { fail(parser, "More than one root value.") }
            return
        }
        switch top {
        case .dictionary(var items, let key):
            guard let key else { return fail(parser, "A value without a key on line \(parser.lineNumber).") }
            items.append(PNode(key: key, value: value))
            stack[stack.count - 1] = .dictionary(items, key: nil)
        case .array(var items):
            items.append(PNode(key: "", value: value))
            stack[stack.count - 1] = .array(items)
        }
    }

    private func fail(_ parser: XMLParser, _ message: String) {
        if error == nil { error = message }
        parser.abortParsing()
    }
}

// MARK: - JSON reader

/// A small JSON parser that, unlike JSONSerialization, keeps object keys in file order.
struct JSONReader {
    let bytes: [UInt8]
    private var i = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
    }

    mutating func document() throws -> PValue {
        skipSpace()
        let v = try value(depth: 0)
        skipSpace()
        guard i == bytes.count else { throw fail("Unexpected text after the JSON value") }
        return v
    }

    private mutating func value(depth: Int) throws -> PValue {
        guard depth < 512 else { throw fail("Nesting is too deep") }
        guard i < bytes.count else { throw fail("Unexpected end of file") }
        switch bytes[i] {
        case UInt8(ascii: "{"):
            i += 1
            var items: [PNode] = []
            skipSpace()
            if peek("}") { i += 1; return .dictionary(items) }
            while true {
                skipSpace()
                guard peek("\"") else { throw fail("Expected a key in quotes") }
                let key = try string()
                skipSpace()
                guard peek(":") else { throw fail("Expected a colon after the key") }
                i += 1
                skipSpace()
                items.append(PNode(key: key, value: try value(depth: depth + 1)))
                skipSpace()
                if peek(",") { i += 1; continue }
                if peek("}") { i += 1; return .dictionary(items) }
                throw fail("Expected a comma or a closing brace")
            }
        case UInt8(ascii: "["):
            i += 1
            var items: [PNode] = []
            skipSpace()
            if peek("]") { i += 1; return .array(items) }
            while true {
                skipSpace()
                items.append(PNode(key: "", value: try value(depth: depth + 1)))
                skipSpace()
                if peek(",") { i += 1; continue }
                if peek("]") { i += 1; return .array(items) }
                throw fail("Expected a comma or a closing bracket")
            }
        case UInt8(ascii: "\""):
            return .string(try string())
        case UInt8(ascii: "t"):
            try literal("true"); return .boolean(true)
        case UInt8(ascii: "f"):
            try literal("false"); return .boolean(false)
        case UInt8(ascii: "n"):
            try literal("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return try number()
        default:
            throw fail("Unexpected character")
        }
    }

    private func peek(_ c: Unicode.Scalar) -> Bool { i < bytes.count && bytes[i] == UInt8(ascii: c) }

    private mutating func skipSpace() {
        while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
    }

    private mutating func literal(_ word: String) throws {
        let w = Array(word.utf8)
        guard bytes.count - i >= w.count, Array(bytes[i..<(i + w.count)]) == w else { throw fail("Unexpected word") }
        i += w.count
    }

    private mutating func number() throws -> PValue {
        let start = i
        var isReal = false
        while i < bytes.count {
            let c = bytes[i]
            if (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) || c == UInt8(ascii: "-") || c == UInt8(ascii: "+") {
                i += 1
            } else if c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
                isReal = true
                i += 1
            } else {
                break
            }
        }
        let text = String(decoding: bytes[start..<i], as: UTF8.self)
        if !isReal, let n = Int(text) { return .integer(n) }
        guard let r = Double(text) else { i = start; throw fail("\"\(text)\" is not a number") }
        return .real(r)
    }

    private mutating func string() throws -> String {
        i += 1
        var out: [UInt8] = []
        while i < bytes.count {
            let c = bytes[i]
            i += 1
            switch c {
            case UInt8(ascii: "\""):
                return String(decoding: out, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard i < bytes.count else { throw fail("Unfinished escape") }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code), bytes.count - i >= 6,
                       bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        let low = try hex4()
                        if (0xDC00...0xDFFF).contains(low) { code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00) }
                    }
                    out.append(contentsOf: Array(String(Unicode.Scalar(code).map(Character.init) ?? "\u{FFFD}").utf8))
                default:
                    throw fail("Unknown escape")
                }
            default:
                if c < 0x20 { throw fail("Control character in a string") }
                out.append(c)
            }
        }
        throw fail("Unfinished string")
    }

    private mutating func hex4() throws -> UInt32 {
        guard bytes.count - i >= 4, let v = UInt32(String(decoding: bytes[i..<(i + 4)], as: UTF8.self), radix: 16) else {
            throw fail("Invalid \\u escape")
        }
        i += 4
        return v
    }

    private func fail(_ message: String) -> CodecError {
        let line = bytes[0..<min(i, bytes.count)].reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) }
        return CodecError(message: "\(message) on line \(line).")
    }
}
