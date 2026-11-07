import Foundation

/// `Hex --selftest`: checks the parsing, formatting, value decoding and the memory-mapped search, including a
/// sparse 5 GB file so the offset maths is proven past 32 bits.
enum SelfTest {
    static func run() -> Int32 {
        var passed = 0, failed = 0
        func check(_ ok: Bool, _ name: String) {
            if ok { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
        }

        // Formatting.
        check(HexFormat.byteStrings[0] == "00" && HexFormat.byteStrings[0xAB] == "AB" && HexFormat.byteStrings[255] == "FF", "byte strings")
        check(HexFormat.hex(0x1F, digits: 8) == "0000001F", "padded hex")
        check(HexFormat.offsetDigits(forCount: 100) == 8, "8 offset digits for small files")
        check(HexFormat.offsetDigits(forCount: 5 << 30) == 10, "10 offset digits past 4 GB")
        check(HexFormat.ascii(0x41) == "A" && HexFormat.ascii(0x00) == "." && HexFormat.ascii(0x7F) == ".", "ASCII column")
        check(HexFormat.hexString([0xDE, 0xAD, 0xBE, 0xEF]) == "DE AD BE EF", "copy as hex")
        check(HexFormat.text(Array("caf\u{E9}\n".utf8)) == "caf\u{E9}\n", "copy as text keeps UTF-8")
        check(HexFormat.text([0x41, 0x00, 0x42]) == "A.B", "copy as text dots control bytes")
        check(HexFormat.text([0x41, 0xFF, 0x42]) == "A.B", "copy as text falls back to ASCII")

        // Hex input.
        check(HexFormat.parseHexBytes("DE AD be ef") == [0xDE, 0xAD, 0xBE, 0xEF], "parse spaced hex")
        check(HexFormat.parseHexBytes("0xCAFE") == [0xCA, 0xFE], "parse 0x hex")
        check(HexFormat.parseHexBytes("ABC") == nil, "reject odd digit count")
        check(HexFormat.parseHexBytes("zz") == nil, "reject non hex")
        check(HexFormat.parseHexBytes("") == nil, "reject empty")

        // Offsets.
        check(HexFormat.parseOffset("100", current: 0, count: 1000) == 100, "decimal offset")
        check(HexFormat.parseOffset("0x100", current: 0, count: 1000) == 256, "0x offset")
        check(HexFormat.parseOffset("1f", current: 0, count: 1000) == 31, "bare hex offset")
        check(HexFormat.parseOffset("20h", current: 0, count: 1000) == 32, "h suffix offset")
        check(HexFormat.parseOffset("+16", current: 10, count: 1000) == 26, "relative forward")
        check(HexFormat.parseOffset("-0x10", current: 40, count: 1000) == 24, "relative back in hex")
        check(HexFormat.parseOffset("1000", current: 0, count: 1000) == nil, "reject past the end")
        check(HexFormat.parseOffset("-5", current: 2, count: 1000) == nil, "reject before the start")
        check(HexFormat.parseOffset("hello", current: 0, count: 1000) == nil, "reject words")

        // Inspector values.
        let le = Inspector.rows([0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], bigEndian: false)
        func value(_ rows: [InspectorRow], _ name: String) -> String? { rows.first { $0.name == name }?.value }
        check(value(le, "UInt16") == Inspector.count(1024), "UInt16 little endian")
        check(value(le, "Int32") == Inspector.count(1024), "Int32 little endian")
        let be = Inspector.rows([0x00, 0x00, 0x04, 0x00], bigEndian: true)
        check(value(be, "UInt32") == Inspector.count(1024), "UInt32 big endian")
        check(value(be, "Int64") == "-", "Int64 needs 8 bytes")
        check(value(Inspector.rows([0xFF], bigEndian: false), "Int8") == "-1", "Int8 sign")
        check(value(Inspector.rows([0xFF], bigEndian: false), "UInt8") == "255", "UInt8")
        check(value(Inspector.rows([0x3F, 0x80, 0x00, 0x00], bigEndian: true), "Float") == "1", "Float 1.0")
        check(value(Inspector.rows([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F], bigEndian: false), "Double") == "1", "Double 1.0")
        check(value(Inspector.rows([0xC0, 0x49, 0x0F, 0xDB], bigEndian: true), "Float")?.replacingOccurrences(of: ",", with: ".").hasPrefix("-3.14159") == true, "Float negative pi")
        check(value(Inspector.rows([0xA5], bigEndian: false), "Binary") == "1010 0101", "binary")
        check(Inspector.utf8(Array("h\u{E9}llo".utf8)) == "h\u{E9}llo", "UTF-8 decode")
        check(Inspector.utf8([0xC3]) == nil, "UTF-8 rejects a cut sequence")

        // Memory-mapped file and search.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HexSelfTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let small = dir.appendingPathComponent("small.bin")
        let content = Array("..MAGIC....MAGIC..".utf8)
        try? Data(content).write(to: small)
        if let src = try? ByteSource.open(small) {
            check(src.count == content.count && src[2] == UInt8(ascii: "M"), "open and read")
            check(src.find(Array("MAGIC".utf8), starts: 0..<src.count, backwards: false) == 2, "find forwards")
            check(src.find(Array("MAGIC".utf8), starts: 3..<src.count, backwards: false) == 11, "find next")
            check(src.find(Array("MAGIC".utf8), starts: 0..<src.count, backwards: true) == 11, "find backwards")
            check(src.find(Array("MAGIC".utf8), starts: 0..<11, backwards: true) == 2, "find previous")
            check(src.find(Array("NOPE".utf8), starts: 0..<src.count, backwards: false) == nil, "not found")
            check(src.bytes(16..<40) == Array("..".utf8), "bytes clamp to the end")
        } else {
            check(false, "open small file")
        }

        check((try? ByteSource.open(dir)) == nil, "folders are refused")
        check((try? ByteSource.open(dir.appendingPathComponent("missing"))) == nil, "missing files are refused")

        let empty = dir.appendingPathComponent("empty.bin")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        check((try? ByteSource.open(empty))?.count == 0, "empty file opens with no bytes")

        // A sparse 5 GB file costs no disk space and proves offsets past 4 GB.
        let big = dir.appendingPathComponent("big.bin")
        let bigSize = 5 << 30
        if FileManager.default.createFile(atPath: big.path, contents: nil), let handle = try? FileHandle(forWritingTo: big) {
            try? handle.truncate(atOffset: UInt64(bigSize))
            try? handle.seek(toOffset: UInt64(bigSize - 100))
            try? handle.write(contentsOf: Data("TAIL".utf8))
            try? handle.close()
            if let src = try? ByteSource.open(big) {
                check(src.count == bigSize, "5 GB file maps")
                check(src[bigSize - 100] == UInt8(ascii: "T") && src[bigSize - 1] == 0, "read past 4 GB")
                check(src.find(Array("TAIL".utf8), starts: (bigSize - (16 << 20))..<bigSize, backwards: false) == bigSize - 100,
                      "find near the end of a 5 GB file")
                check(src.find(Array("TAIL".utf8), starts: (bigSize - (16 << 20))..<bigSize, backwards: true) == bigSize - 100,
                      "find backwards in a 5 GB file")
                var stopped = 0
                let r = src.find(Array("TAIL".utf8), starts: 0..<bigSize, backwards: false, cancelled: { stopped += 1; return true })
                check(r == nil && stopped == 1, "search stops when cancelled")
            } else {
                check(false, "map a 5 GB sparse file")
            }
        } else {
            check(false, "create a sparse file")
        }

        // Model behaviour.
        let ok = MainActor.assumeIsolated { () -> Bool in
            let model = HexModel(demo: Array(0..<64), name: "t.bin", cursor: 4, length: 4, bookmarks: [])
            guard model.selection == 4...7, model.selectedBytes == [4, 5, 6, 7] else { return false }
            guard model.jump(to: "0x20"), model.selection == 32...32, !model.jump(to: "999") else { return false }
            model.addBookmark()
            guard model.bookmarks.count == 1, model.isBookmarked(32), !model.isBookmarked(33) else { return false }
            model.select(0...0)
            model.goToBookmark(next: true)
            return model.cursor == 32
        }
        check(ok, "model selection, jump and bookmarks")

        let bookmarks = [Bookmark(offset: 5, length: 2, name: "x")]
        let round = (try? JSONDecoder().decode([Bookmark].self, from: JSONEncoder().encode(bookmarks))) ?? []
        check(round == bookmarks, "bookmarks round trip")

        print("\(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
