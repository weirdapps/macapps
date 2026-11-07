import Foundation

// MARK: - Data

/// One row of a key and value table: query params, headers, form fields, environment variables.
struct Pair: Codable, Hashable, Identifiable {
    var id = UUID()
    var enabled = true
    var key = ""
    var value = ""

    var isBlank: Bool { key.isEmpty && value.isEmpty }
}

enum HTTPMethod: String, Codable, CaseIterable, Identifiable {
    case GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS
    var id: String { rawValue }
}

enum BodyKind: String, Codable, CaseIterable, Identifiable {
    case none, json, form, raw
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .json: "JSON"
        case .form: "Form"
        case .raw: "Raw"
        }
    }
}

struct APIRequest: Codable, Hashable, Identifiable {
    var id = UUID()
    var name = "New Request"
    var method: HTTPMethod = .GET
    var url = ""
    var params: [Pair] = []
    var headers: [Pair] = []
    var bodyKind: BodyKind = .none
    var body = ""
    var form: [Pair] = []
}

struct RequestCollection: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var requests: [APIRequest] = []
}

struct RequestEnvironment: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var variables: [Pair] = []

    /// Enabled variables by name; a later duplicate wins.
    var values: [String: String] {
        var out: [String: String] = [:]
        for v in variables where v.enabled && !v.key.trimmingCharacters(in: .whitespaces).isEmpty {
            out[v.key.trimmingCharacters(in: .whitespaces)] = v.value
        }
        return out
    }
}

struct Workspace: Codable, Equatable {
    var collections: [RequestCollection] = []
    var environments: [RequestEnvironment] = []
    var activeEnvironment: UUID?
}

struct HistoryEntry: Codable, Hashable, Identifiable {
    var id = UUID()
    var date: Date
    var request: APIRequest
    var url: String
    var status: Int?
    var duration: TimeInterval
    var size: Int
}

enum History {
    static let limit = 200

    /// Puts `entry` first and keeps the newest `limit` entries.
    static func adding(_ entry: HistoryEntry, to list: [HistoryEntry]) -> [HistoryEntry] {
        Array(([entry] + list).prefix(limit))
    }
}

// MARK: - Variables

/// `{{name}}` substitution from the active environment.
enum Template {
    /// Variable names in order of first appearance, without duplicates.
    static func names(in s: String) -> [String] {
        var out: [String] = []
        var rest = s[...]
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            let name = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !out.contains(name) { out.append(name) }
            rest = rest[close.upperBound...]
        }
        return out
    }

    /// Replaces every known `{{name}}`; unknown ones stay as typed. Values may refer to other variables.
    static func resolve(_ s: String, _ vars: [String: String]) -> String {
        var current = s
        for _ in 0..<5 {
            let next = once(current, vars)
            if next == current { break }
            current = next
        }
        return current
    }

    /// The variable names in `s` that the environment does not define.
    static func unresolved(in s: String, _ vars: [String: String]) -> [String] {
        names(in: resolve(s, vars))
    }

    private static func once(_ s: String, _ vars: [String: String]) -> String {
        var out = ""
        var rest = s[...]
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            out += rest[..<open.lowerBound]
            let name = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            out += vars[name] ?? String(rest[open.lowerBound..<close.upperBound])
            rest = rest[close.upperBound...]
        }
        return out + rest
    }
}

// MARK: - Building

struct Header: Hashable {
    var name: String
    var value: String
}

/// A request with variables resolved, params in the URL and the body encoded: what goes on the wire.
struct BuiltRequest: Equatable {
    var method: HTTPMethod
    var url: String
    var headers: [Header]
    var body: String?

    var urlRequest: URLRequest? {
        guard let u = URL(string: url) else { return nil }
        var r = URLRequest(url: u, timeoutInterval: 60)
        r.httpMethod = method.rawValue
        for h in headers { r.addValue(h.value, forHTTPHeaderField: h.name) }
        r.httpBody = body.map { Data($0.utf8) }
        return r
    }
}

enum BuildError: Error, Equatable, LocalizedError {
    case emptyURL
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .emptyURL: "Type a URL to send the request to."
        case .invalidURL(let u): "\u{201C}\(u)\u{201D} is not a valid http or https URL."
        }
    }
}

enum Builder {
    /// Characters left as they are in query keys and values and form fields.
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ s: String, form: Bool = false) -> String {
        let e = s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
        return form ? e.replacingOccurrences(of: "%20", with: "+") : e
    }

    static func build(_ r: APIRequest, vars: [String: String]) throws -> BuiltRequest {
        let res = { (s: String) in Template.resolve(s, vars) }
        var url = res(r.url).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { throw BuildError.emptyURL }
        if !url.contains("://") { url = "http://" + url }

        let query = r.params.filter { $0.enabled && !$0.key.isEmpty }
            .map { encode(res($0.key)) + "=" + encode(res($0.value)) }
            .joined(separator: "&")
        if !query.isEmpty {
            var fragment = ""
            if let hash = url.firstIndex(of: "#") {
                fragment = String(url[hash...])
                url = String(url[..<hash])
            }
            if !url.contains("?") { url += "?" } else if !url.hasSuffix("?"), !url.hasSuffix("&") { url += "&" }
            url += query + fragment
        }
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(), ["http", "https"].contains(scheme),
              parsed.host?.isEmpty == false else { throw BuildError.invalidURL(url) }

        var headers = r.headers.filter { $0.enabled && !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { Header(name: res($0.key).trimmingCharacters(in: .whitespaces), value: res($0.value)) }
        func defaultType(_ type: String) {
            if !headers.contains(where: { $0.name.lowercased() == "content-type" }) { headers.append(Header(name: "Content-Type", value: type)) }
        }

        var body: String?
        switch r.bodyKind {
        case .none: break
        case .json:
            body = res(r.body)
            defaultType("application/json")
        case .raw:
            body = res(r.body)
            defaultType("text/plain; charset=utf-8")
        case .form:
            body = r.form.filter { $0.enabled && !$0.key.isEmpty }
                .map { encode(res($0.key), form: true) + "=" + encode(res($0.value), form: true) }
                .joined(separator: "&")
            defaultType("application/x-www-form-urlencoded")
        }
        return BuiltRequest(method: r.method, url: url, headers: headers, body: body)
    }
}

// MARK: - curl

enum Curl {
    /// Wraps `s` in single quotes for a POSIX shell.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A curl command that sends the same request, one option per line.
    static func command(_ b: BuiltRequest) -> String {
        var parts = ["curl"]
        if b.method == .HEAD {
            parts.append("--head")
        } else if !(b.method == .GET && b.body == nil) && !(b.method == .POST && b.body != nil) {
            parts.append("-X \(b.method.rawValue)")
        }
        parts.append(quote(b.url))
        var lines = [parts.joined(separator: " ")]
        for h in b.headers { lines.append("-H " + quote("\(h.name): \(h.value)")) }
        if let body = b.body { lines.append("--data-raw " + quote(body)) }
        return lines.joined(separator: " \\\n  ")
    }
}

// MARK: - JSON

enum JSONTokenKind: Equatable { case key, string, number, literal, punctuation, space }

struct JSONToken: Equatable {
    var kind: JSONTokenKind
    var text: String
}

enum JSONFormat {
    /// Nil when `text` is valid JSON, else a short reason. Empty text counts as valid.
    static func validate(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            _ = try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])
            return nil
        } catch let error as NSError {
            let reason = error.userInfo["NSDebugDescription"] as? String ?? "Not valid JSON."
            return reason.hasSuffix(".") ? reason : reason + "."
        }
    }

    /// Re-indents valid JSON with two spaces, keeping key order and the original number and string spelling.
    static func pretty(_ text: String) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, validate(text) == nil else { return nil }
        var out = ""
        var depth = 0
        let chars = Array(text)
        var i = 0
        func newline() { out += "\n" + String(repeating: "  ", count: depth) }
        func nextSignificant(after j: Int) -> Character? {
            var k = j + 1
            while k < chars.count, chars[k].isWhitespace { k += 1 }
            return k < chars.count ? chars[k] : nil
        }
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\"":
                var j = i + 1
                while j < chars.count, chars[j] != "\"" { j += chars[j] == "\\" ? 2 : 1 }
                out += String(chars[i...min(j, chars.count - 1)])
                i = j
            case "{", "[":
                out.append(c)
                let close: Character = c == "{" ? "}" : "]"
                if nextSignificant(after: i) == close {
                    out.append(close)
                    var k = i + 1
                    while chars[k] != close { k += 1 }
                    i = k
                } else {
                    depth += 1
                    newline()
                }
            case "}", "]":
                depth -= 1
                newline()
                out.append(c)
            case ",":
                out.append(c)
                newline()
            case ":":
                out += ": "
            default:
                if !c.isWhitespace { out.append(c) }
            }
            i += 1
        }
        return out
    }

    /// Splits JSON text into tokens for colouring; a string followed by a colon is a key.
    static func tokens(_ text: String) -> [JSONToken] {
        let chars = Array(text)
        var out: [JSONToken] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                var j = i + 1
                while j < chars.count, chars[j] != "\"" { j += chars[j] == "\\" ? 2 : 1 }
                j = min(j, chars.count - 1)
                var k = j + 1
                while k < chars.count, chars[k].isWhitespace { k += 1 }
                let isKey = k < chars.count && chars[k] == ":"
                out.append(JSONToken(kind: isKey ? .key : .string, text: String(chars[i...j])))
                i = j + 1
            } else if c.isWhitespace {
                var j = i
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                out.append(JSONToken(kind: .space, text: String(chars[i..<j])))
                i = j
            } else if "{}[]:,".contains(c) {
                out.append(JSONToken(kind: .punctuation, text: String(c)))
                i += 1
            } else {
                var j = i
                while j < chars.count, !chars[j].isWhitespace, !"{}[]:,\"".contains(chars[j]) { j += 1 }
                let word = String(chars[i..<j])
                out.append(JSONToken(kind: ["true", "false", "null"].contains(word) ? .literal : .number, text: word))
                i = j
            }
        }
        return out
    }
}

// MARK: - Response

struct HTTPResult: Equatable {
    var status: Int
    var headers: [Header]
    var body: Data
    var duration: TimeInterval
    var url: String

    var contentType: String { headers.first { $0.name.lowercased() == "content-type" }?.value ?? "" }
    var text: String? { String(data: body, encoding: .utf8) }
    var isJSON: Bool {
        contentType.contains("json") || (text.map { JSONFormat.validate($0) == nil && !$0.isEmpty && "{[".contains($0.trimmingCharacters(in: .whitespacesAndNewlines).first ?? " ") } ?? false)
    }

    /// A sensible file name for Save Response.
    var suggestedFileName: String {
        let ext: String
        if isJSON { ext = "json" } else if contentType.contains("html") { ext = "html" } else if contentType.contains("xml") { ext = "xml" }
        else if contentType.contains("png") { ext = "png" } else if contentType.contains("jpeg") { ext = "jpg" } else if text != nil { ext = "txt" } else { ext = "bin" }
        return "response.\(ext)"
    }
}

enum Format {
    static func duration(_ t: TimeInterval) -> String {
        t < 1 ? "\(Int((t * 1000).rounded())) ms" : String(format: "%.2f s", t)
    }

    static func size(_ bytes: Int) -> String {
        bytes < 1000 ? "\(bytes) B" : ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func reason(_ code: Int) -> String {
        let known: [Int: String] = [
            100: "Continue", 101: "Switching Protocols", 200: "OK", 201: "Created", 202: "Accepted", 204: "No Content",
            206: "Partial Content", 301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified",
            307: "Temporary Redirect", 308: "Permanent Redirect", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
            404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable", 408: "Request Timeout", 409: "Conflict",
            410: "Gone", 413: "Content Too Large", 415: "Unsupported Media Type", 418: "I'm a Teapot",
            422: "Unprocessable Content", 429: "Too Many Requests", 500: "Internal Server Error", 501: "Not Implemented",
            502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout",
        ]
        return known[code] ?? HTTPURLResponse.localizedString(forStatusCode: code).capitalized
    }
}
