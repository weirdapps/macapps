import AppKit
import Foundation

/// `Plot --selftest`: checks parsing, number reading, series extraction, persistence and export.
@MainActor
enum SelfTest {
    private static var failures = 0
    private static var checks = 0

    private static func check(_ ok: Bool, _ name: String) {
        checks += 1
        if !ok {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    static func run() -> Int32 {
        // Numbers as people type them.
        check(Number.parse("1,234.5") == 1234.5, "US thousands")
        check(Number.parse("1.234,5") == 1234.5, "European thousands")
        check(Number.parse("48,5") == 48.5, "decimal comma")
        check(Number.parse("1,234") == 1234, "comma thousands without decimals")
        check(Number.parse("1.234.567") == 1_234_567, "dot thousands")
        check(Number.parse("$12") == 12 && Number.parse("45%") == 45 && Number.parse("€ 3,50") == 3.5, "currency and percent")
        check(Number.parse("(300)") == -300 && Number.parse("\u{2212}2.5") == -2.5, "accounting and Unicode minus")
        check(Number.parse("") == nil && Number.parse("abc") == nil && Number.parse("nan") == nil && Number.parse("inf") == nil, "non-numbers")
        check(Number.parse("1e3") == 1000, "exponent")
        check(Number.short(1250) == Number.short(1250.0) && !Number.short(12_500).contains("12500"), "short labels compact large values")

        // Delimiters and quoting.
        check(DataTable.delimiter(for: "a\tb\n1\t2") == "\t", "tab delimiter")
        check(DataTable.delimiter(for: "x;y\n1,5;2,5\n2,5;3,5") == ";", "semicolon delimiter with decimal commas")
        check(DataTable.delimiter(for: "x,y\n1,2\n3,4") == ",", "comma delimiter")
        let quoted = DataTable.split("name,value\n\"Smith, J\",\"1,200\"\n\"He said \"\"hi\"\"\",3", by: ",")
        check(quoted.count == 3 && quoted[1] == ["Smith, J", "1,200"] && quoted[2][0] == "He said \"hi\"", "quoted fields")
        let multiline = DataTable.split("a,b\n\"two\nlines\",1", by: ",")
        check(multiline.count == 2 && multiline[1][0] == "two\nlines", "newline inside quotes")

        // Tables from pasted text.
        let tsv = DataTable.parse("Quarter\t2024\t2025\r\nQ1\t182\t214\r\nQ2\t205\t241\r\n\r\n")
        check(tsv?.headers == ["Quarter", "2024", "2025"] && tsv?.rows.count == 2, "TSV with header and CRLF")
        check(tsv?.series.map(\.name) == ["2024", "2025"] && tsv?.series[1].values == [214, 241], "series from columns")
        let noHeader = DataTable.parse("A,1,2\nB,3,4")
        check(noHeader?.headers == ["Label", "Series 1", "Series 2"] && noHeader?.rows.count == 2, "headerless table gets names")
        check(DataTable.parse("\tA\tB\nx\t1\t2")?.headers == ["Label", "A", "B"], "blank corner cell means a header row")
        check(DataTable.parse("Jan,2024,2025\nFeb,5,6")?.rows.count == 1, "year headers are detected")
        let column = DataTable.parse("5\n8\n13")
        check(column?.labels == ["1", "2", "3"] && column?.series.first?.values == [5, 8, 13], "single column gets row labels")
        let namedColumn = DataTable.parse("Score\n5\n8")
        check(namedColumn?.series.first?.name == "Score" && namedColumn?.rows.count == 2, "single column with header")
        check(DataTable.parse("") == nil && DataTable.parse("just words\nmore words") == nil, "text without numbers is rejected")
        let ragged = DataTable.parse("x,a,b\n1,2\n3,4,5")
        check(ragged?.rows.allSatisfy { $0.count == 3 } == true && ragged?.series[1].values == [nil, 5], "ragged rows are padded")

        // Labels, x values and gaps.
        let dupes = DataTable(headers: ["L", "S", "S"], rows: [["Jan", "1", "2"], ["Jan", "x", "3"], ["", "4", ""]])
        check(dupes.labels == ["Jan", "Jan (2)", "3"], "duplicate and blank labels made unique")
        check(dupes.series.map(\.name) == ["S", "S (2)"], "duplicate series names made unique")
        check(dupes.series[0].values == [1, nil, 4], "non-numeric cells become gaps")
        check(DataTable.parse("x,y\n1,2\n2.5,3")?.xValues == [1, 2.5] && dupes.xValues == [1, 2, 3], "scatter x from numbers or row numbers")

        // Editing.
        var t = DataTable.blank
        t.set(row: 0, column: 0, to: "A")
        t.set(row: 0, column: 1, to: "7")
        t.set(row: 5, column: 0, to: "skipped")
        check(t.rows == [["A", "7"]], "typing in the spare row appends exactly one row")
        t.addColumn()
        t.addRow()
        check(t.columnCount == 3 && t.rows.count == 2 && t.rows.allSatisfy { $0.count == 3 }, "add row and series")
        check(t.filledRows.count == 1, "blank rows are not plotted")
        t.removeColumn(0)
        check(t.columnCount == 3, "label column cannot be removed")
        t.removeColumn(2)
        t.removeColumn(1)
        check(t.columnCount == 2, "last series cannot be removed")

        // Round trips.
        let tricky = DataTable(headers: ["Name", "Value"], rows: [["a\tb", "1"], ["say \"x\"", "2"]])
        check(DataTable.parse(tricky.text()) == tricky, "TSV text round trip with quotes")
        check(DataTable.parse(Demo.visitors.table.text(separator: ",")) == Demo.visitors.table, "CSV text round trip")
        let encoded = try? JSONEncoder().encode(Demo.all)
        let decoded = encoded.flatMap { try? JSONDecoder().decode([PlotChart].self, from: $0) }
        check(decoded == Demo.all, "JSON persistence round trip")

        // Chart data.
        check(Demo.revenue.points.count == 12 && Demo.revenue.legendNames == ["2024", "2025", "2026"], "bar points and legend")
        var pie = Demo.share
        pie.table.rows[1][1] = "-3"
        check(pie.slices.count == 4 && pie.legendNames.count == 4, "pie skips non-positive slices")
        check(Demo.all.allSatisfy(\.isPlottable) && !PlotChart(title: "", table: .blank).isPlottable, "plottable state")
        check(PaletteName.plot.colors(10).count == 10, "palette cycles")

        // Export.
        if let rep = Exporter.image(Demo.revenue, scale: 2) {
            check(rep.pixelsWide == 1920 && rep.pixelsHigh == 1200, "PNG at 2x is 1920 by 1200")
        } else {
            check(false, "PNG renders")
        }
        check(Exporter.image(Demo.share, scale: 3)?.pixelsWide == 2880, "PNG at 3x")
        let pdf = Exporter.pdf(Demo.energy)
        check(pdf.count > 1000 && pdf.prefix(4) == Data("%PDF".utf8), "PDF renders")
        let pdfURL = FileManager.default.temporaryDirectory.appendingPathComponent("plot-selftest-\(UUID().uuidString).pdf")
        try? pdf.write(to: pdfURL)
        let page = CGPDFDocument(pdfURL as CFURL)?.page(at: 1)?.getBoxRect(.mediaBox)
        check(page?.size == Exporter.size, "PDF page is the chart size")
        try? FileManager.default.removeItem(at: pdfURL)
        check(Exporter.fileName(PlotChart(title: "a/b: c", table: .blank)) == "a-b- c", "export file names are safe")

        // Review fixes: odd input that used to slip through.
        check(Number.parse("0x1F") == nil && Number.parse("-inf") == nil && Number.parse("1_000") == nil, "hex and words are not numbers")
        let bom = DataTable.parse("\u{FEFF}1,2\n3,4")
        check(bom?.labelsAreNumeric == true && bom?.xValues == [1, 3], "UTF-8 byte order mark is stripped")
        let bomColumn = DataTable.parse("\u{FEFF}5\n8")
        check(bomColumn?.series.first?.values == [5, 8], "byte order mark does not turn a number into a header")
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("Item\tCount\r\nA\t3".data(using: .utf16LittleEndian)!)
        check(DataTable.decode(utf16).flatMap(DataTable.parse)?.series.first?.values == [3], "UTF-16 text from Excel")
        check(DataTable.decode(Data([0x80, 0x2C, 0x35]))?.hasPrefix("\u{20AC}") == true, "Windows Latin fallback keeps the euro sign")
        check(DataTable.unique(["Jan", "Jan", "Jan (2)"]).count == Set(DataTable.unique(["Jan", "Jan", "Jan (2)"])).count, "suffixed names stay unique")
        let clash = DataTable(headers: ["L", "A", "A", "A (2)"], rows: [["x", "1", "2", "3"]])
        check(Set(clash.series.map(\.name)).count == 3, "series names never collide")
        check(DataTable.parse("Jan,2024,2025\nFeb,2031,2040")?.rows.count == 2, "a first row of years is data when the rest are years too")
        let raggedJSON = Data(#"{"headers":["L","S"],"rows":[["a"],["b","2","9"],[]]}"#.utf8)
        let decodedTable = try? JSONDecoder().decode(DataTable.self, from: raggedJSON)
        check(decodedTable?.rows.allSatisfy { $0.count == decodedTable?.columnCount } == true && decodedTable?.series.count == 2, "damaged saved tables are padded on load")
        let old = Data(#"[{"title":"Old","table":{"headers":["L","S"],"rows":[["a","1"]]},"kind":"donut"}]"#.utf8)
        let oldCharts = try? JSONDecoder().decode([PlotChart].self, from: old)
        check(oldCharts?.first?.title == "Old" && oldCharts?.first?.kind == .bar && oldCharts?.first?.showLegend == true, "charts with missing or unknown fields still load")
        let big = (0..<(DataTable.maxRows + 250)).map { "r\($0),\($0)" }.joined(separator: "\n")
        let bigRead = DataTable.read("Row,Value\n" + big)
        check(bigRead?.table.rows.count == DataTable.maxRows && bigRead?.dropped == 250, "huge pastes are capped and the cut is reported")
        let started = Date()
        let bigChart = PlotChart(title: "Big", table: bigRead!.table)
        check(bigChart.points.count == DataTable.maxRows && bigChart.table.axisLabels().count <= 10 && Date().timeIntervalSince(started) < 2, "a capped table plots quickly with a thinned axis")
        check(Demo.visitors.table.axisLabels() == Demo.visitors.table.labels, "short tables label every category")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("plot-selftest-\(UUID().uuidString).csv")
        try? Data("\u{FEFF}Month,Sales\nJan,5\nFeb,7".utf8).write(to: tmp)
        if case let .table(table, dropped) = DataTable.load(tmp) {
            check(table.headers == ["Month", "Sales"] && dropped == 0, "CSV file loads")
        } else {
            check(false, "CSV file loads")
        }
        try? FileManager.default.removeItem(at: tmp)
        let model = PlotModel(persisting: false, charts: [Demo.revenue])
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        undo.beginUndoGrouping()
        model.setCell(Demo.revenue.id, row: 0, column: 1, to: "999")
        model.registerCellEdit(Demo.revenue.id, row: 0, column: 1, from: "182", to: "999")
        undo.endUndoGrouping()
        check(model.charts[0].table.rows[0][1] == "999" && undo.undoActionName == "Typing", "cell edits are one undo step")
        undo.undo()
        check(model.charts[0].table.rows[0][1] == "182", "undo restores the cell")
        undo.redo()
        check(model.charts[0].table.rows[0][1] == "999", "redo puts the edit back")

        print(failures == 0 ? "All \(checks) checks passed" : "\(failures) of \(checks) checks failed")
        return failures == 0 ? 0 : 1
    }
}
