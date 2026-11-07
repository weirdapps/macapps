import Foundation
import UniformTypeIdentifiers

/// `Plist --selftest`: the codecs, conversions and tree edits, without any UI.
enum SelfTest {
    nonisolated(unsafe) private static var failures = 0
    nonisolated(unsafe) private static var checks = 0

    private static func check(_ ok: Bool, _ name: String) {
        checks += 1
        if !ok {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    static let sampleXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        	<key>Zebra</key>
        	<string>a &amp; b &lt;c&gt;</string>
        	<key>Apple</key>
        	<integer>-42</integer>
        	<key>Pi</key>
        	<real>3.25</real>
        	<key>On</key>
        	<true/>
        	<key>Off</key>
        	<false/>
        	<key>When</key>
        	<date>2026-11-07T10:30:00Z</date>
        	<key>Bytes</key>
        	<data>
        	SGVsbG8=
        	</data>
        	<key>List</key>
        	<array>
        		<string>one</string>
        		<dict/>
        		<array/>
        	</array>
        	<key>Empty</key>
        	<string></string>
        </dict>
        </plist>
        """

    static func run() -> Int32 {
        // XML parsing keeps order and types.
        let xml = try? Codec.parseXML(Data(sampleXML.utf8))
        check(xml?.children?.map(\.key) == ["Zebra", "Apple", "Pi", "On", "Off", "When", "Bytes", "List", "Empty"], "XML keeps key order")
        check(xml?.children?[0].value == .string("a & b <c>"), "XML entities decode")
        check(xml?.children?[1].value == .integer(-42), "XML integer")
        check(xml?.children?[2].value == .real(3.25), "XML real")
        check(xml?.children?[3].value == .boolean(true) && xml?.children?[4].value == .boolean(false), "XML booleans")
        check(xml?.children?[5].value == .date(Date(timeIntervalSince1970: 1_794_047_400)), "XML date")
        check(xml?.children?[6].value == .data(Data("Hello".utf8)), "XML data across lines")
        check(xml?.children?[7].children?.map(\.value.type) == [.string, .dictionary, .array], "XML nested array")

        // XML writing round trips and matches Foundation.
        if let xml {
            let text = Codec.xml(xml)
            let again = try? Codec.parseXML(Data(text.utf8))
            check(again.map { $0.isSame(as: xml) } ?? false, "XML round trip")
            let ours = try? PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? NSDictionary
            let theirs = try? PropertyListSerialization.propertyList(from: Data(sampleXML.utf8), format: nil) as? NSDictionary
            check(ours != nil && ours == theirs, "Written XML reads back the same in Foundation")
            check(text.contains("\t<key>Zebra</key>\n\t<string>a &amp; b &lt;c&gt;</string>"), "XML layout matches Apple's")

            // Binary.
            let bin = try? Codec.binary(xml)
            var format = PropertyListSerialization.PropertyListFormat.xml
            _ = bin.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: &format) }
            check(format == .binary, "Binary output is a binary plist")
            let read = bin.flatMap { try? Codec.read($0) }
            check(read?.1 == .binary, "Binary detected on read")
            check(read.map { $0.0.sorted().isSame(as: xml.sorted()) } ?? false, "Binary round trip")
        }

        // JSON.
        let jsonText = #"{"name": "Café 😀", "z": 1, "a": [true, null, 2.5, -3e2], "nested": {"k": "line\nbreak \"q\""}}"#
        let json = try? Codec.parseJSON(Data(jsonText.utf8))
        check(json?.children?.map(\.key) == ["name", "z", "a", "nested"], "JSON keeps key order")
        check(json?.children?[0].value == .string("Café 😀"), "JSON unicode escapes and surrogate pairs")
        check(json?.children?[1].value == .integer(1), "JSON integer")
        check(json?.children?[2].children?.map(\.value) == [.boolean(true), .null, .real(2.5), .real(-300)], "JSON array values")
        if let json {
            let out = Codec.json(json)
            check((try? Codec.parseJSON(Data(out.utf8)))?.isSame(as: json) ?? false, "JSON round trip")
            check((try? JSONSerialization.jsonObject(with: Data(out.utf8))) != nil, "Written JSON is valid for Foundation")
            check(out.hasPrefix("{\n  \"name\": "), "JSON is pretty printed")
            let plist = Codec.xml(json)
            check(!plist.contains("null"), "Nulls are left out of property lists")
        }
        check((try? Codec.parseJSON(Data("{\"a\": 1,}".utf8))) == nil, "JSON trailing comma is an error")
        do {
            _ = try Codec.parseJSON(Data("{\n\"a\": tru}".utf8))
            check(false, "Bad JSON throws")
        } catch {
            check(error.localizedDescription.contains("line 2"), "JSON errors name the line")
        }

        // Format detection.
        check((try? Codec.read(Data(sampleXML.utf8)))?.1 == .xml, "XML detected")
        check((try? Codec.read(Data("  [1, 2]".utf8)))?.1 == .json, "JSON detected")
        let openStep = try? Codec.read(Data("{ a = 1; b = (x, y); }".utf8))
        check(openStep?.1 == .xml && openStep?.0.children?.count == 2, "Old-style plists open")
        check((try? Codec.read(Data("hello there".utf8))) == nil, "Junk is rejected")
        check(PlistDocument.format(for: .json, current: .binary) == .json
              && PlistDocument.format(for: .propertyList, current: .json) == .xml
              && PlistDocument.format(for: .propertyList, current: .binary) == .binary, "Saved format follows the file type")

        // Text formats.
        check(Format.hex(Data([0x48, 0x65, 0x6c, 0x6c, 0x6f])) == "<48656c6c 6f>", "Hex display")
        check(Format.parseHex("<48656c6c 6f>") == Data("Hello".utf8), "Hex parse")
        check(Format.parseHex("abc") == nil && Format.parseHex("zz") == nil, "Bad hex is rejected")
        check(Format.number("1.5", preferReal: false) == .real(1.5) && Format.number("7", preferReal: false) == .integer(7)
              && Format.number("7", preferReal: true) == .real(7) && Format.number("x", preferReal: false) == nil, "Number parsing")
        let inf = try? Codec.parseXML(Data(Codec.xml(PNode(key: "Root", value: .array([PNode(key: "", value: .real(-.infinity))]))).utf8))
        check(inf?.children?.first?.value == .real(-.infinity), "Infinity round trips")

        // Type conversion.
        check(PValue.string("42").converted(to: .number) == .integer(42), "String to number")
        check(PValue.integer(5).converted(to: .string) == .string("5"), "Number to string")
        check(PValue.string("YES").converted(to: .boolean) == .boolean(true), "String to boolean")
        check(PValue.string("Hi").converted(to: .data) == .data(Data("Hi".utf8)), "String to data")
        check(PValue.array([PNode(key: "", value: .integer(1))]).converted(to: .dictionary).text == "1 key/value pair", "Array to dictionary")
        check(PValue.dictionary([PNode(key: "k", value: .integer(1))]).converted(to: .string) == .string(""), "Container to string")

        // Tree edits.
        var tree = PNode(key: "Root", value: .dictionary([]))
        let a = PNode(key: "a", value: .integer(1)), b = PNode(key: "b", value: .array([]))
        let c = PNode(key: "", value: .string("c"))
        tree.insert(a, in: tree.id, at: 0)
        tree.insert(b, in: tree.id, at: 1)
        tree.insert(c, in: b.id, at: 0)
        check(tree.count == 4 && tree.location(of: c.id)?.parent == b.id, "Insert into nested containers")
        check(tree.move(a.id, by: 1) && tree.children?.map(\.key) == ["b", "a"], "Move down")
        check(!tree.move(a.id, by: 1), "Move past the end is refused")
        check(tree.move(a.id, by: -1) && tree.children?.map(\.key) == ["a", "b"], "Move up")
        check(tree.path(to: c.id)?.map(\.key) == ["Root", "b", ""], "Path to a nested item")
        check(tree.remove(b.id)?.id == b.id && tree.count == 2, "Remove a container with its contents")
        check(PNode.uniqueKey("New item", in: [PNode(key: "New item", value: .null), PNode(key: "New item 2", value: .null)]) == "New item 3", "Unique keys")

        // Outline rows and filtering.
        if let xml {
            let list = xml.children![7]
            check(Outline.rows(xml, expanded: [], filter: "").count == 10, "Collapsed rows")
            check(Outline.rows(xml, expanded: [list.id], filter: "").count == 13, "Expanded rows")
            let hits = Outline.rows(xml, expanded: [], filter: "one")
            check(hits.map(\.key) == ["Root", "List", ""], "Filter shows matches with their ancestors")
            check(Outline.rows(xml, expanded: [], filter: "nothing here").count == 1, "Filter with no matches")
            let dupes = PNode(key: "Root", value: .dictionary([PNode(key: "x", value: .null), PNode(key: "x", value: .null)]))
            check(Outline.rows(dupes, expanded: [], filter: "").filter(\.isDuplicate).count == 2, "Duplicate keys are flagged")
        }

        // Undo through the document.
        let doc = PlistDocument()
        let undo = UndoManager()
        undo.groupsByEvent = false
        doc.undoManager = undo
        undo.beginUndoGrouping()
        doc.update("Add Item") { $0.insert(PNode(key: "k", value: .string("v")), in: doc.root.id, at: 0) }
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        doc.setFormat(.binary)
        undo.endUndoGrouping()
        check(doc.root.children?.count == 1 && doc.format == .binary && undo.undoActionName == "Change Format", "Edits register undo")
        undo.undo()
        check(doc.format == .xml && doc.root.children?.count == 1, "Undo format change")
        undo.undo()
        check(doc.root.children?.isEmpty == true, "Undo add")
        undo.redo()
        check(doc.root.children?.first?.key == "k", "Redo add")

        print(failures == 0 ? "All \(checks) checks passed." : "\(failures) of \(checks) checks failed.")
        return failures == 0 ? 0 : 1
    }
}
