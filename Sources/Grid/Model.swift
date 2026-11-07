import Foundation

// The pure part of Grid: decoding, delimiter and header detection, the RFC 4180 parser, sorting,
// filtering, column statistics and the CSV, TSV and Markdown writers. Nothing here touches the UI.

enum TextEncoding: String, CaseIterable, Identifiable, Sendable {
    case utf8, utf16LE, utf16BE, latin1

    var id: String { rawValue }

    var label: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf16LE: "UTF-16 LE"
        case .utf16BE: "UTF-16 BE"
        case .latin1: "Latin 1"
        }
    }
}

enum Delimiter: UInt8, CaseIterable, Identifiable, Sendable {
    case comma = 44, tab = 9, semicolon = 59, pipe = 124

    var id: UInt8 { rawValue }
    var character: String { String(UnicodeScalar(rawValue)) }

    var label: String {
        switch self {
        case .comma: "Comma"
        case .tab: "Tab"
        case .semicolon: "Semicolon"
        case .pipe: "Pipe"
        }
    }
}

enum CopyFormat: String, CaseIterable, Sendable {
    case csv, tsv, markdown

    var label: String {
        switch self {
        case .csv: "CSV"
        case .tsv: "TSV"
        case .markdown: "Markdown"
        }
    }
}

struct ValueCount: Equatable, Sendable {
    var value: String
    var count: Int
}

struct ColumnStats: Equatable, Sendable {
    var rows = 0      // Rows looked at.
    var count = 0     // Non-empty cells.
    var empty = 0
    var unique = 0
    var isNumeric = false
    var isInteger = false
    /// The most decimal places any number in the column is written with, so min, max and sum read like the cells.
    var decimals = 0
    var min: String?
    var max: String?
    var mean: Double?
    var sum: Double?
    var top: [ValueCount] = []
}

enum CSV {
    static let quote: UInt8 = 34
    static let lf: UInt8 = 10
    static let cr: UInt8 = 13

    // MARK: Encoding

    /// Picks the encoding from a byte order mark, the zero bytes of BOM-less UTF-16, or UTF-8 validity, falling back to Latin 1.
    static func decode(_ data: Data) -> (text: String, encoding: TextEncoding) {
        let bytes = [UInt8](data.prefix(4096))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return (decode(data, as: .utf8), .utf8) }
        if bytes.starts(with: [0xFF, 0xFE]) { return (decode(data, as: .utf16LE), .utf16LE) }
        if bytes.starts(with: [0xFE, 0xFF]) { return (decode(data, as: .utf16BE), .utf16BE) }
        if bytes.count >= 4 {
            // Mostly ASCII text in UTF-16 has a zero in every other byte: odd positions for little endian, even for big.
            var evenZeros = 0, oddZeros = 0
            for (i, b) in bytes.enumerated() where b == 0 {
                if i % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 }
            }
            let half = bytes.count / 2
            if oddZeros > half * 4 / 10 && evenZeros < half / 10 { return (decode(data, as: .utf16LE), .utf16LE) }
            if evenZeros > half * 4 / 10 && oddZeros < half / 10 { return (decode(data, as: .utf16BE), .utf16BE) }
        }
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        return (decode(data, as: .latin1), .latin1)
    }

    /// Decodes with a given encoding, dropping a byte order mark. Invalid bytes never fail: they become replacement characters.
    static func decode(_ data: Data, as encoding: TextEncoding) -> String {
        switch encoding {
        case .utf8:
            let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
            return String(data: body, encoding: .utf8) ?? String(decoding: body, as: UTF8.self)
        case .utf16LE:
            return utf16(data.starts(with: [0xFF, 0xFE]) ? data.dropFirst(2) : data[...], bigEndian: false)
        case .utf16BE:
            return utf16(data.starts(with: [0xFE, 0xFF]) ? data.dropFirst(2) : data[...], bigEndian: true)
        case .latin1:
            // Windows Latin 1 is what spreadsheets write; plain ISO Latin 1 decodes the few bytes it leaves undefined.
            return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) ?? ""
        }
    }

    /// UTF-16 without a BOM. A lone surrogate or an odd last byte becomes a replacement character instead of losing the whole file.
    static func utf16(_ body: Data, bigEndian: Bool) -> String {
        let even = body.count % 2 == 0 ? body : body.dropLast()
        if let text = String(data: even, encoding: bigEndian ? .utf16BigEndian : .utf16LittleEndian) { return text }
        let units = stride(from: even.startIndex, to: even.endIndex, by: 2).map { i -> UInt16 in
            let a = UInt16(even[i]), b = UInt16(even[i + 1])
            return bigEndian ? a << 8 | b : b << 8 | a
        }
        return String(decoding: units, as: UTF16.self)
    }

    // MARK: Parsing

    /// Parses RFC 4180 text: quoted fields may hold delimiters, doubled quotes and line breaks; CRLF, LF and CR all end a record.
    /// Blank lines are skipped. `progress` gets the fraction done about every megabyte and stops the parse by returning false.
    static func parse(_ text: String, delimiter: Delimiter, maxRows: Int = .max,
                      progress: ((Double) -> Bool)? = nil) -> [[String]]? {
        var text = text
        let delim = delimiter.rawValue
        return text.withUTF8 { buf -> [[String]]? in
            let n = buf.count
            var rows: [[String]] = []
            var row: [String] = []
            var width = 8
            row.reserveCapacity(width)
            var field: [UInt8] = []
            var lastReport = 0
            var i = 0
            while i < n {
                if buf[i] == quote {
                    i += 1
                    field.removeAll(keepingCapacity: true)
                    while i < n {
                        let b = buf[i]
                        if b == quote {
                            if i + 1 < n && buf[i + 1] == quote { field.append(quote); i += 2 } else { i += 1; break }
                        } else {
                            field.append(b)
                            i += 1
                        }
                    }
                    // Anything between a closing quote and the delimiter is kept, as spreadsheets do.
                    while i < n, buf[i] != delim, buf[i] != lf, buf[i] != cr { field.append(buf[i]); i += 1 }
                    row.append(String(decoding: field, as: UTF8.self))
                } else {
                    let start = i
                    while i < n, buf[i] != delim, buf[i] != lf, buf[i] != cr { i += 1 }
                    row.append(String(decoding: UnsafeBufferPointer(rebasing: buf[start..<i]), as: UTF8.self))
                }
                if i < n && buf[i] == delim {
                    i += 1
                    if i == n { row.append("") }
                    continue
                }
                // End of record.
                if !(row.count == 1 && row[0].isEmpty) {
                    width = Swift.max(width, row.count)
                    rows.append(row)
                    if rows.count >= maxRows { return rows }
                }
                row = []
                row.reserveCapacity(width)
                if i < n {
                    if buf[i] == cr && i + 1 < n && buf[i + 1] == lf { i += 2 } else { i += 1 }
                }
                if let progress, i - lastReport > 1 << 20 {
                    lastReport = i
                    if !progress(Double(i) / Double(n)) { return nil }
                }
            }
            if !row.isEmpty && !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            return rows
        }
    }

    /// The delimiter that splits the first lines into the most consistent number of fields above one.
    static func detectDelimiter(_ text: String, preferred: Delimiter? = nil) -> Delimiter {
        let sample = String(text.prefix(65_536))
        // Byte counts, not characters: counting the characters of a 100 MB string takes a while.
        let truncated = sample.utf8.count < text.utf8.count
        var best: (Delimiter, Double)?
        let order = [preferred].compactMap { $0 } + Delimiter.allCases.filter { $0 != preferred }
        for d in order {
            guard var rows = parse(sample, delimiter: d, maxRows: 60) else { continue }
            if truncated && rows.count > 1 { rows.removeLast() }
            let counts = rows.map(\.count)
            guard !counts.isEmpty else { continue }
            var freq: [Int: Int] = [:]
            for c in counts { freq[c, default: 0] += 1 }
            let (mode, hits) = freq.max { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }!
            guard mode > 1 else { continue }
            let score = Double(hits) / Double(counts.count) * 1000 + Double(Swift.min(mode, 100))
            if best == nil || score > best!.1 { best = (d, score) }
        }
        return best?.0 ?? preferred ?? .comma
    }

    /// Whether the first row names the columns: it votes per column, like Python's csv.Sniffer, on whether
    /// the first cell differs in kind from the cells below it.
    static func detectHeader(_ rows: [[String]], decimalComma: Bool = false) -> Bool {
        guard rows.count >= 2, let first = rows.first else { return false }
        let body = rows.dropFirst().prefix(60)
        var votes = 0
        for (c, head) in first.enumerated() {
            let values = body.map { c < $0.count ? $0[c] : "" }.filter { !$0.isEmpty }
            guard !values.isEmpty else { continue }
            let numeric = values.filter { number($0, decimalComma: decimalComma) != nil }.count
            if Double(numeric) >= Double(values.count) * 0.8 {
                votes += number(head, decimalComma: decimalComma) == nil && !head.isEmpty ? 1 : -1
            } else if head.isEmpty || values.contains(head) {
                votes -= 1
            } else {
                let lengths = Set(values.map(\.count))
                if lengths.count == 1 && head.count != lengths.first! { votes += 1 }
            }
        }
        if votes == 0 {
            // A tie: a row of distinct, non-empty labels with no numbers in it reads as a header.
            return Set(first).count == first.count && first.allSatisfy { !$0.isEmpty && number($0, decimalComma: decimalComma) == nil }
        }
        return votes > 0
    }

    /// A number written the way CSV files write them: optional sign, digits, a decimal point, an exponent.
    /// Words like "inf", hex and thousands separators are text.
    /// With `decimalComma`, as in semicolon files from European spreadsheets, "1.234,5" is 1234.5.
    static func number(_ s: String, decimalComma: Bool = false) -> Double? {
        var t = s.utf8.first == 32 || s.utf8.last == 32 ? s.trimmingCharacters(in: .whitespaces) : s
        if decimalComma && t.utf8.contains(44) {
            t = t.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        }
        guard let first = t.utf8.first, first == 43 || first == 45 || first == 46 || (48...57).contains(first) else { return nil }
        for b in t.utf8 where !((48...57).contains(b) || b == 46 || b == 45 || b == 43 || b == 101 || b == 69) { return nil }
        guard let v = Double(t), v.isFinite else { return nil }
        return v
    }

    // MARK: Sorting and filtering

    /// Natural, case-insensitive order: "file 2" before "file 10". ASCII takes a fast path; anything else uses Finder's order.
    static func naturalCompare(_ a: String, _ b: String) -> ComparisonResult {
        var a = a, b = b
        let fast: ComparisonResult? = a.withUTF8 { pa in
            b.withUTF8 { pb in
                var i = 0, j = 0
                while i < pa.count && j < pb.count {
                    let x = pa[i], y = pb[j]
                    if x >= 0x80 || y >= 0x80 { return nil }
                    let dx = x >= 48 && x <= 57, dy = y >= 48 && y <= 57
                    if dx && dy {
                        while i < pa.count && pa[i] == 48 && i + 1 < pa.count && pa[i + 1] >= 48 && pa[i + 1] <= 57 { i += 1 }
                        while j < pb.count && pb[j] == 48 && j + 1 < pb.count && pb[j + 1] >= 48 && pb[j + 1] <= 57 { j += 1 }
                        var ei = i, ej = j
                        while ei < pa.count && pa[ei] >= 48 && pa[ei] <= 57 { ei += 1 }
                        while ej < pb.count && pb[ej] >= 48 && pb[ej] <= 57 { ej += 1 }
                        if ei - i != ej - j { return ei - i < ej - j ? .orderedAscending : .orderedDescending }
                        while i < ei {
                            if pa[i] != pb[j] { return pa[i] < pb[j] ? .orderedAscending : .orderedDescending }
                            i += 1; j += 1
                        }
                        continue
                    }
                    let lx = x >= 65 && x <= 90 ? x + 32 : x, ly = y >= 65 && y <= 90 ? y + 32 : y
                    if lx != ly { return lx < ly ? .orderedAscending : .orderedDescending }
                    i += 1; j += 1
                }
                let ra = pa.count - i, rb = pb.count - j
                return ra == rb ? .orderedSame : ra < rb ? .orderedAscending : .orderedDescending
            }
        }
        return fast ?? a.localizedStandardCompare(b)
    }

    /// Whether most non-empty cells of a column are numbers, judged on up to `limit` rows.
    static func isNumericColumn(_ rows: [[String]], column: Int, from start: Int, limit: Int = 2000, decimalComma: Bool = false) -> Bool {
        var count = 0, numeric = 0
        var r = start
        while r < rows.count && count < limit {
            if column < rows[r].count, !rows[r][column].isEmpty {
                count += 1
                if number(rows[r][column], decimalComma: decimalComma) != nil { numeric += 1 }
            }
            r += 1
        }
        return count > 0 && Double(numeric) >= Double(count) * 0.95
    }

    /// Row indices from `start` sorted by one column. Numeric columns sort by value; empty cells always go last;
    /// equal keys keep their file order. Returns nil when cancelled.
    static func sortedOrder(_ rows: [[String]], from start: Int, column: Int, ascending: Bool, decimalComma: Bool = false,
                            isCancelled: () -> Bool = { false }) -> [Int]? {
        let indices = Array(start..<Swift.max(start, rows.count))
        let numeric = isNumericColumn(rows, column: column, from: start, limit: .max, decimalComma: decimalComma)
        // Rank 0 sorts by number, rank 1 by text, rank 2 is empty.
        var rank = [UInt8](repeating: 2, count: rows.count)
        var values = [Double](repeating: 0, count: numeric ? rows.count : 0)
        // The column's cells in one flat array: far fewer lookups than rows[x][column] in the comparator.
        var keys = [String](repeating: "", count: rows.count)
        for r in indices {
            guard column < rows[r].count, !rows[r][column].isEmpty else { continue }
            if numeric, let v = number(rows[r][column], decimalComma: decimalComma) {
                rank[r] = 0
                values[r] = v
            } else {
                rank[r] = 1
                keys[r] = rows[r][column]
            }
        }
        if isCancelled() { return nil }
        let sorted = indices.sorted { x, y in
            if rank[x] != rank[y] { return rank[x] < rank[y] }
            switch rank[x] {
            case 0:
                if values[x] != values[y] { return ascending ? values[x] < values[y] : values[x] > values[y] }
            case 1:
                let c = naturalCompare(keys[x], keys[y])
                if c != .orderedSame { return ascending ? c == .orderedAscending : c == .orderedDescending }
            default: break
            }
            return x < y
        }
        return isCancelled() ? nil : sorted
    }

    /// The rows of `order` with `query` in any cell, or in `column` when one is given. Case-insensitive.
    static func filter(_ rows: [[String]], order: [Int], query: String, column: Int? = nil,
                       isCancelled: () -> Bool = { false }) -> [Int]? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return order }
        let match: (String) -> Bool
        if q.utf8.allSatisfy({ $0 < 0x80 }) {
            let needle = Array(q.lowercased().utf8)
            match = { asciiContains($0, needle) }
        } else {
            match = { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        var out: [Int] = []
        for (n, r) in order.enumerated() {
            if n & 0x3FFF == 0 && isCancelled() { return nil }
            let row = rows[r]
            if let column {
                if column < row.count && match(row[column]) { out.append(r) }
            } else if row.contains(where: match) {
                out.append(r)
            }
        }
        return out
    }

    /// Case-insensitive substring test for an ASCII, lowercased needle.
    static func asciiContains(_ haystack: String, _ needle: [UInt8]) -> Bool {
        var h = haystack
        return h.withUTF8 { p in
            let n = needle.count
            guard n <= p.count else { return false }
            if n == 0 { return true }
            let first = needle[0]
            var i = 0
            while i <= p.count - n {
                var b = p[i]
                if b >= 65 && b <= 90 { b += 32 }
                if b == first {
                    var k = 1
                    while k < n {
                        var c = p[i + k]
                        if c >= 65 && c <= 90 { c += 32 }
                        if c != needle[k] { break }
                        k += 1
                    }
                    if k == n { return true }
                }
                i += 1
            }
            return false
        }
    }

    // MARK: Statistics

    static func stats(_ rows: [[String]], indices: [Int], column: Int, decimalComma: Bool = false,
                      isCancelled: () -> Bool = { false }) -> ColumnStats? {
        var s = ColumnStats()
        s.rows = indices.count
        var counts: [String: Int] = [:]
        var numericCount = 0, integers = true, places = 0
        var sum = 0.0, lo = Double.infinity, hi = -Double.infinity
        var textMin: String?, textMax: String?
        for (n, r) in indices.enumerated() {
            if n & 0x3FFF == 0 && isCancelled() { return nil }
            let v = column < rows[r].count ? rows[r][column] : ""
            if v.isEmpty { s.empty += 1; continue }
            s.count += 1
            counts[v, default: 0] += 1
            if let d = number(v, decimalComma: decimalComma) {
                numericCount += 1
                sum += d
                lo = Swift.min(lo, d)
                hi = Swift.max(hi, d)
                if d.rounded() != d || v.contains(decimalComma ? "," : ".") { integers = false }
                let u = v.utf8
                if let dot = u.lastIndex(of: decimalComma ? 44 : 46), !u.contains(101), !u.contains(69) {
                    let trimmed = u.reversed().prefix { $0 == 32 }.count
                    places = Swift.max(places, Swift.min(6, u.distance(from: dot, to: u.endIndex) - 1 - trimmed))
                }
            } else {
                if textMin == nil || naturalCompare(v, textMin!) == .orderedAscending { textMin = v }
                if textMax == nil || naturalCompare(v, textMax!) == .orderedDescending { textMax = v }
            }
        }
        s.unique = counts.count
        s.isNumeric = s.count > 0 && Double(numericCount) >= Double(s.count) * 0.95
        if s.isNumeric {
            s.isInteger = integers
            s.decimals = integers ? 0 : Swift.max(places, lo.rounded() != lo || hi.rounded() != hi ? 1 : 0)
            s.sum = sum
            s.mean = sum / Double(numericCount)
            s.min = format(lo, decimals: s.decimals)
            s.max = format(hi, decimals: s.decimals)
        } else {
            s.min = textMin
            s.max = textMax
        }
        s.top = counts.sorted { $0.value == $1.value ? naturalCompare($0.key, $1.key) == .orderedAscending : $0.value > $1.value }
            .prefix(5).map { ValueCount(value: $0.key, count: $0.value) }
        return s
    }

    /// The user's number format; the website screenshot always uses US English.
    static let locale = CommandLine.arguments.contains("--snapshot") ? Locale(identifier: "en_US") : Locale.autoupdatingCurrent

    /// NumberFormatter, unlike format styles, honours the separators a person picked in System Settings.
    static func format(_ v: Double, integer: Bool = false) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.maximumFractionDigits = integer ? 0 : abs(v) >= 1000 ? 2 : 4
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    static func format(_ n: Int) -> String { format(Double(n), integer: true) }

    /// A number with exactly `decimals` places, grouped the user's way.
    static func format(_ v: Double, decimals: Int) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = decimals
        f.maximumFractionDigits = decimals
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    // MARK: Writing

    /// One field for a delimited file: quoted when it holds the delimiter, a quote or a line break.
    static func field(_ s: String, delimiter: Character) -> String {
        guard s.contains(where: { $0 == delimiter || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func line(_ cells: [String], delimiter: Character) -> String {
        cells.map { field($0, delimiter: delimiter) }.joined(separator: String(delimiter))
    }

    /// Rows as CSV, TSV or a Markdown table. Markdown always has a header row and right-aligns numeric columns.
    static func serialize(header: [String]?, rows: [[String]], format: CopyFormat, columns: Int,
                          numeric: Set<Int> = []) -> String {
        func pad(_ r: [String]) -> [String] { r.count >= columns ? Array(r.prefix(columns)) : r + Array(repeating: "", count: columns - r.count) }
        switch format {
        case .csv, .tsv:
            let d: Character = format == .csv ? "," : "\t"
            let lines = (header.map { [pad($0)] } ?? []) + rows.map(pad)
            return lines.map { line($0, delimiter: d) }.joined(separator: "\r\n")
        case .markdown:
            func cell(_ s: String) -> String {
                s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\r\n", with: "<br>")
                    .replacingOccurrences(of: "\n", with: "<br>").replacingOccurrences(of: "\r", with: "<br>")
            }
            let head = pad(header ?? (0..<columns).map(columnLetter))
            var out = "| " + head.map(cell).joined(separator: " | ") + " |\n"
            out += "| " + (0..<columns).map { numeric.contains($0) ? "---:" : "---" }.joined(separator: " | ") + " |"
            for r in rows { out += "\n| " + pad(r).map(cell).joined(separator: " | ") + " |" }
            return out
        }
    }

    /// Spreadsheet column names: A ... Z, AA, AB ...
    static func columnLetter(_ index: Int) -> String {
        var n = index + 1, s = ""
        while n > 0 {
            let r = (n - 1) % 26
            s = String(UnicodeScalar(UInt8(65 + r))) + s
            n = (n - 1) / 26
        }
        return s
    }

    /// Writes header and rows as UTF-8 CSV, in chunks, so a million rows never build one giant string.
    /// It writes a temporary file and moves it into place only when complete, so a failure or a cancel
    /// never leaves half a file behind, nor damages a file being replaced.
    static func export(header: [String]?, rows: [[String]], order: [Int], columns: Int, to url: URL,
                       isCancelled: () -> Bool = { false }) throws {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        let scratch = (try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true))
            ?? fm.temporaryDirectory.appendingPathComponent("Grid-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let temp = scratch.appendingPathComponent(url.lastPathComponent)
        try write(header: header, rows: rows, order: order, columns: columns, to: temp, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: url)
        }
    }

    private static func write(header: [String]?, rows: [[String]], order: [Int], columns: Int, to url: URL,
                              isCancelled: () -> Bool) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        func pad(_ r: [String]) -> [String] { r.count >= columns ? Array(r.prefix(columns)) : r + Array(repeating: "", count: columns - r.count) }
        var chunk = ""
        if let header { chunk = line(pad(header), delimiter: ",") + "\r\n" }
        for r in order {
            chunk += line(pad(rows[r]), delimiter: ",") + "\r\n"
            if chunk.utf8.count > 1 << 20 {
                if isCancelled() { throw CancellationError() }
                try handle.write(contentsOf: Data(chunk.utf8))
                chunk = ""
            }
        }
        try handle.write(contentsOf: Data(chunk.utf8))
    }
}
