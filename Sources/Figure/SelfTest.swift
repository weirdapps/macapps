import AppKit

/// `Figure --selftest`: exercises the tokenizer, parser, evaluator, formatting and sheet persistence.
enum SelfTest {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    static func expect(_ line: String, _ want: String?, _ file: Int = #line) {
        checks += 1
        let got = Engine.result(line)
        if got != want {
            failures += 1
            print("FAIL: \"\(line)\" gave \(got ?? "nothing"), wanted \(want ?? "nothing") (line \(file))")
        }
    }

    /// Evaluates a whole sheet and compares the displayed results line by line.
    static func sheet(_ text: String, _ want: [String?], _ file: Int = #line) {
        checks += 1
        let got = Engine.evaluate(text).map(\.display)
        if got != want {
            failures += 1
            print("FAIL: sheet at line \(file) gave \(got), wanted \(want)")
        }
    }

    static func check(_ ok: Bool, _ what: String) {
        checks += 1
        if !ok { failures += 1; print("FAIL: \(what)") }
    }

    static func run() -> Int32 {
        // Arithmetic and precedence.
        expect("2 + 3 * 4", "14")
        expect("(2 + 3) * 4", "20")
        expect("10 - 4 - 3", "3")
        expect("2^3^2", "512")
        expect("-2^2", "-4")
        expect("2 ** 10", "1,024")
        expect("7 / 2", "3.5")
        expect("1 / 3", "0.333333")
        expect("0.1 + 0.2", "0.3")
        expect("3 × 4 ÷ 6", "2")
        expect("3 x 4", "12")
        expect("17 mod 5", "2")
        expect("10 % 3", "1")
        expect("2pi", "6.283185")
        expect("3(4 + 5)", "27")
        expect("1,234,567 + 1", "1,234,568")
        expect("1.5e3", "1,500")
        expect("10 / 0", nil)
        expect("(2 + 3", nil)
        expect("2 +", nil)

        // Percentages.
        expect("20% of 150", "30")
        expect("150 + 10%", "165")
        expect("150 - 10%", "135")
        expect("200 * 15%", "30")
        expect("25% off $80", "$60.00")
        expect("15%", "15%")
        expect("10% + 5%", "15%")

        // Currency symbols are numbers that remember their symbol.
        expect("$1,200 + $300", "$1,500.00")
        expect("950€ * 12", "€11,400.00")
        expect("-$5 + $2", "-$3.00")
        expect("$300 / $50", "6")
        expect("32 h × €45", "€1,440.00")

        // Units and conversions.
        expect("10 km in mi", "6.21 mi")
        expect("5 mi to km", "8.05 km")
        expect("70 kg in lb", "154.32 lb")
        expect("1 lb as g", "453.59 g")
        expect("100 C in F", "212°F")
        expect("98.6 F in C", "37°C")
        expect("0 C in K", "273.15 K")
        expect("90 minutes in hours", "1.5 h")
        expect("3 h + 45 min", "3.75 h")
        expect("2 km + 500 m", "2.5 km")
        expect("12 in in cm", "30.48 cm")
        expect("12 in", "12 in")
        expect("1 day + 12 h", "1.5 days")
        expect("10 km / 500 m", "20")
        expect("5 km + 3 kg", nil)
        expect("5 kg in mi", nil)

        // Functions and constants.
        expect("sqrt(144)", "12")
        expect("sqrt 16 + 9", "13")
        expect("round(3.14159, 2)", "3.14")
        expect("round(2.5)", "3")
        expect("abs(-7.5)", "7.5")
        expect("sin(30°)", "0.5")
        expect("cos(0)", "1")
        expect("sin(pi)", "0")
        expect("log(1000)", "3")
        expect("ln(e)", "1")
        expect("pi", "3.141593")
        expect("sqrt(-1)", nil)
        expect("round($3.456, 2)", "$3.46")

        // Notes: comments, labels and prose.
        expect("# a heading", nil)
        expect("12 + 3 # with a comment", "15")
        expect("Groceries: $64.20", "$64.20")
        expect("Remember to book the taxi", nil)
        expect("Rooms for 4 people", nil)
        expect("10:30", nil)

        // Variables and references to lines above.
        sheet("rent = 950\nrent * 12", ["950", "11,400"])
        sheet("a = 2\nb = a + 3\na * b", ["2", "5", "10"])
        sheet("x = 4\n2x", ["4", "8"])
        sheet("10\n20\nprev * 2", ["10", "20", "40"])
        sheet("10\n# note\nans + 1", ["10", nil, "11"])
        sheet("10\n20\n30\nsum", ["10", "20", "30", "60"])
        sheet("$5\n$7.50\ntotal\nhello\naverage", ["$5.00", "$7.50", "$12.50", nil, "$6.25"])
        sheet("100\n\n1\n2\ntotal", ["100", nil, "1", "2", "3"])
        sheet("# Trip\n2 km\n800 m\ntotal", [nil, "2 km", "800 m", "2.8 km"])
        sheet("1\n2\ntotal\n4\ntotal", ["1", "2", "3", "4", "7"])
        sheet("prev", [nil])
        sheet("pi = 3", [nil])
        sheet("g = 9.81\nt = 2\n0.5 × g × t^2", ["9.81", "2", "19.62"])
        sheet("walk: 7.2 km in mi\nbudget = $2,400\nbudget - 10%", ["4.47 mi", "$2,400.00", "$2,160.00"])

        // Pasted text with other line endings keeps one result per line, like the editor's lines.
        sheet("1\r\n2\r\nsum", ["1", "2", "3"])
        sheet("4\r5\rprev * 2", ["4", "5", "10"])
        sheet("6\u{2028}7\u{2029}total", ["6", "7", "13"])
        check(Engine.lines("a\r\nb\n").count == 3, "CRLF counts as one line break")
        check(Sheet(text: "\r\n# Groceries\r\n$5").title == "Groceries", "title with CRLF")

        // Money and measurements do not mix.
        expect("$5 + 3 km", nil)
        expect("3 km - $5", nil)
        expect("$5 in km", nil)
        sheet("$5\n3 km\ntotal", ["$5.00", "3 km", nil])

        // Odd input: empty, zero, negatives, unicode names, overflow.
        sheet("", [nil])
        check(Sheet(text: "").lastResult == nil, "empty sheet has no last result")
        expect("0 * 5", "0")
        expect("-0", "0")
        expect("0 / 0", nil)
        expect("-5 km in mi", "-3.11 mi")
        expect("-40 C in F", "-40°F")
        expect("10^400", nil)
        expect("1e400", nil)
        expect("🙂 + 1", nil)
        sheet("ενοίκιο = 950\nενοίκιο × 2", ["950", "1,900"])
        sheet("café = 3.5\ncafé * 2", ["3.5", "7"])
        expect(String(repeating: "(", count: 200) + "1" + String(repeating: ")", count: 200), "1")

        // A long sheet stays quick enough to evaluate on every keystroke.
        let long = (0..<3000).map { $0 % 7 == 6 ? "total" : "item \($0): $\($0 % 50).25 × 2" }.joined(separator: "\n")
        let clock = ContinuousClock.now
        let longResults = Engine.evaluate(long)
        check(longResults.count == 3000 && longResults.allSatisfy { $0.value != nil }, "long sheet evaluates every line")
        check(ContinuousClock.now - clock < .seconds(1.5), "long sheet evaluates in under 1.5 s")

        // Every result gets a click target, including lines a partial redraw skipped.
        MainActor.assumeIsolated {
            let view = SheetTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
            view.string = (1...80).map { $0 % 10 == 0 ? "# note" : "\($0) km in mi" }.joined(separator: "\n")
            view.fitContainer()
            view.results = Engine.evaluate(view.string)
            let slots = view.layoutResults()
            check(slots.count == 72, "a click target for every result (\(slots.count))")
            check(zip(slots, slots.dropFirst()).allSatisfy { $0.textRect.minY < $1.textRect.minY }, "results stack top to bottom")
            check(slots.last.map { $0.pill.minY > 300 } == true, "results below the fold are placed too")
            check(slots.allSatisfy { $0.pill.maxX <= view.bounds.width }, "results stay inside the view")
        }

        // Formatting.
        check(Format.number(1234567.891, maxFraction: 2) == "1,234,567.89", "grouping with decimals")
        check(Format.number(-0.0000001, maxFraction: 2) == "-1e-07", "tiny numbers go scientific")
        check(Format.number(-0.001, maxFraction: 2) == "0", "negative zero after rounding")
        check(Format.number(2e20, maxFraction: 2) == "2e20", "huge numbers go scientific")

        // Tokens carry their position for colouring, in UTF-16 units.
        let scanned = Lexer.scan("€5 + rent # note")
        check(scanned.tokens.count == 4 && scanned.tokens[3].range == NSRange(location: 5, length: 4), "token ranges")
        check(scanned.commentStart == 10, "comment start")
        let roles = Highlight.ranges("rent = 950 km", result: Engine.evaluate("rent = 950 km")[0]).map(\.1)
        check(roles == [.assignment, .unit], "highlight roles")

        // Sheets: titles, export text and a JSON round trip through a temporary file.
        let s = Sheet(text: "# Weekend away\nhotel = $135 × 2\nnotes")
        check(s.title == "Weekend away", "sheet title")
        check(Sheet(text: "\n  \n").title == "Untitled", "untitled sheet")
        check(s.lastResult == "$270.00", "last result")
        check(s.textWithResults.contains("hotel = $135 × 2  = $270.00") && s.textWithResults.hasSuffix("\nnotes"), "export text")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("figure-selftest-\(UUID().uuidString).json")
        do {
            try JSONEncoder().encode(Demo.sheets).write(to: url)
            let back = try JSONDecoder().decode([Sheet].self, from: Data(contentsOf: url))
            check(back == Demo.sheets, "sheets round trip")
        } catch {
            check(false, "sheets round trip threw \(error)")
        }
        try? FileManager.default.removeItem(at: url)

        // Every demo line that looks like a calculation produces a result.
        for sheet in Demo.sheets + [Sheet(text: Demo.welcome)] {
            let lines = Engine.lines(sheet.text)
            for (line, r) in zip(lines, Engine.evaluate(sheet.text)) {
                let isProse = line.isEmpty || line.hasPrefix("#") || line.hasPrefix("Type ") || line.hasPrefix("Click ")
                check(isProse || r.value != nil, "demo line \"\(line)\" has a result")
            }
        }

        print(failures == 0 ? "All \(checks) checks passed" : "\(failures) of \(checks) checks failed")
        return failures == 0 ? 0 : 1
    }
}
