import Foundation

enum SelfTest {
    static func run() -> Int32 {
        var passed = 0
        var failed = 0
        func check(_ ok: Bool, _ what: String) {
            if ok { passed += 1 } else { failed += 1; print("FAIL: \(what)") }
        }
        let all = PeriodicTable.elements

        // The data parses completely and in order.
        check(all.count == 118, "118 elements parsed (got \(all.count))")
        check(all.map(\.number) == Array(1...118), "numbers are 1...118 in order")
        check(Set(all.map(\.symbol)).count == 118, "symbols are unique")
        check(Set(all.map(\.name)).count == 118, "names are unique")

        // A sample of symbols, names and masses.
        let sample: [(Int, String, String)] = [(1, "H", "Hydrogen"), (6, "C", "Carbon"), (11, "Na", "Sodium"), (19, "K", "Potassium"),
                                               (26, "Fe", "Iron"), (47, "Ag", "Silver"), (50, "Sn", "Tin"), (74, "W", "Tungsten"),
                                               (79, "Au", "Gold"), (80, "Hg", "Mercury"), (82, "Pb", "Lead"), (92, "U", "Uranium"),
                                               (106, "Sg", "Seaborgium"), (118, "Og", "Oganesson")]
        for (z, sym, name) in sample {
            let e = PeriodicTable.element(z)
            check(e?.symbol == sym && e?.name == name, "element \(z) is \(sym) \(name)")
        }
        check(PeriodicTable.element(6)?.mass == 12.011, "carbon weighs 12.011")
        check(PeriodicTable.element(43)?.massIsIsotope == true && PeriodicTable.element(43)?.massText == "[98]", "technetium shows [98]")
        check(zip(all, all.dropFirst()).filter { $0.mass > $1.mass }.map { $0.0.number }.sorted() == [18, 27, 52, 90, 92, 94, 107],
              "masses rise except the known inversions (Ar/K, Co/Ni, Te/I, Th/Pa, ...)")

        // Every symbol is one capital and at most one lowercase letter.
        check(all.allSatisfy { $0.symbol.range(of: "^[A-Z][a-z]?$", options: .regularExpression) != nil }, "symbols are well formed")

        // Layout: every element has a unique cell in the 18-column grid.
        let cells = all.map { "\($0.row),\($0.column)" }
        check(Set(cells).count == 118, "grid cells are unique")
        check(all.allSatisfy { (1...18).contains($0.column) && [1, 2, 3, 4, 5, 6, 7, 9, 10].contains($0.row) }, "cells are in range")
        check(PeriodicTable.element(2)?.column == 18 && PeriodicTable.element(118)?.column == 18, "noble gases sit in group 18")
        check(PeriodicTable.element(57)?.row == 9 && PeriodicTable.element(103)?.row == 10, "f-block rows hold La and Lr")
        check(PeriodicTable.element(72)?.group == 4 && PeriodicTable.element(72)?.period == 6, "hafnium is group 4, period 6")
        check(PeriodicTable.element(64)?.period == 6 && PeriodicTable.element(64)?.block == "f", "gadolinium is in the f-block")
        check(all.filter { $0.category == .lanthanide }.count == 15 && all.filter { $0.category == .actinide }.count == 15, "15 lanthanides and 15 actinides")
        check(all.filter { $0.category == .nobleGas }.map(\.number) == [2, 10, 18, 36, 54, 86], "noble gases")

        // Electron counts in the configurations add up to the atomic number.
        let cores = ["[He]": 2, "[Ne]": 10, "[Ar]": 18, "[Kr]": 36, "[Xe]": 54, "[Rn]": 86]
        let badConfigs = all.filter { e in
            var total = 0
            for part in e.configuration.split(separator: " ") {
                if let core = cores[String(part)] { total += core; continue }
                guard let i = part.firstIndex(where: { "spdf".contains($0) }), let n = Int(part[part.index(after: i)...]) else { return true }
                total += n
            }
            return total != e.number
        }
        check(badConfigs.isEmpty, "configurations add up to Z (bad: \(badConfigs.map(\.symbol)))")
        check(Format.superscripted("[Ar] 3d10 4s2") == "[Ar] 3d¹⁰ 4s²", "configurations render with superscripts")

        // Physical data.
        let gases = all.filter { $0.phase == .gas }.map(\.number)
        check(gases == [1, 2, 7, 8, 9, 10, 17, 18, 36, 54, 86], "eleven gases at room temperature (got \(gases))")
        check(all.filter { $0.phase == .liquid }.map(\.number) == [35, 80], "bromine and mercury are the liquids")
        check(PeriodicTable.element(31)?.phase == .solid && PeriodicTable.element(6)?.phase == .solid, "gallium and carbon are solid")
        check(all.allSatisfy { e in
            guard let m = e.melting, let b = e.boiling else { return true }
            return m < b
        }, "melting points are below boiling points")
        check(all.compactMap(\.electronegativity).allSatisfy { (0.6...4.0).contains($0) }, "electronegativities are in range")
        check(all.max { ($0.electronegativity ?? 0) < ($1.electronegativity ?? 0) }?.symbol == "F", "fluorine is the most electronegative")
        check(all.max { ($0.density ?? 0) < ($1.density ?? 0) }?.symbol == "Os", "osmium is the densest")
        check(all.filter { $0.year == nil }.count == 10, "ten elements known since antiquity")
        check(PeriodicTable.element(117)?.year == 2010 && PeriodicTable.element(15)?.year == 1669, "discovery years")

        // Formatting.
        check(Format.temperature(1811) == "1811 K (1537.9 °C)", "temperature formatting (got \(Format.temperature(1811)))")
        check(PeriodicTable.element(8)?.densityText == "1.429 g/L", "gas density in g/L")
        check(PeriodicTable.element(26)?.densityText == "7.874 g/cm³", "solid density in g/cm³")

        // Search.
        func search(_ q: String) -> [Int] {
            all.filter { $0.matches(q) }.sorted { ($0.rank(q), $0.number) < ($1.rank(q), $1.number) }.map(\.number)
        }
        check(search("26") == [26], "search by number")
        check(search("fe").first == 26, "search by symbol")
        check(search("Gold") == [79], "search by name")
        check(search("aluminum") == [13], "search by American spelling")
        check(search("ium").count > 40, "search inside names")
        check(search("xyz").isEmpty, "no match")
        check(search("c").first == 6, "symbol match ranks first")

        // Keyboard navigation.
        check(PeriodicTable.neighbour(of: 1, dr: 0, dc: 1) == 2, "right from H reaches He")
        check(PeriodicTable.neighbour(of: 4, dr: 0, dc: 1) == 5, "right from Be skips the gap to B")
        check(PeriodicTable.neighbour(of: 21, dr: 1, dc: 0) == 39, "down from Sc is Y")
        check(PeriodicTable.neighbour(of: 39, dr: 1, dc: 0) == 57, "down from Y skips to La")
        check(PeriodicTable.neighbour(of: 87, dr: 1, dc: 0) == 87, "down from Fr stays")
        check(PeriodicTable.neighbour(of: 89, dr: -1, dc: 0) == 57, "up from Ac is La")
        check(PeriodicTable.neighbour(of: 118, dr: 0, dc: 1) == 118, "right from Og stays")

        // Heat scale.
        check(Heat.isDark(1) && !Heat.isDark(0), "heat scale text contrast")
        check(ColorMode.mass.range.lowerBound == 1.008, "mass range starts at hydrogen")

        // Model state.
        MainActor.assumeIsolated {
            let m = TableModel.demo
            m.highlightedCategory = .halogen
            m.highlightedPhase = .gas
            m.mode = .state
            check(m.highlightedCategory == nil && m.highlightedPhase == nil, "changing the colour mode clears a stuck legend highlight")
            let before = UserDefaults.standard.object(forKey: "selected") as? Int
            m.selected = 117
            m.mode = .mass
            check(UserDefaults.standard.object(forKey: "selected") as? Int == before, "the demo model never writes user settings")
            m.query = "zz"
            m.selectFirstResult()
            check(m.selected == 117, "Return with no match keeps the selection")
            m.query = "  au "
            m.selectFirstResult()
            check(m.selected == 79, "Return selects the best match (Au)")
            m.query = ""
            check(m.results.isEmpty && PeriodicTable.elements.allSatisfy(m.isLit), "an empty search lights every tile")
        }
        check(PeriodicTable.element(0) == nil && PeriodicTable.element(119) == nil && PeriodicTable.element(-3) == nil, "out of range numbers find nothing")
        check(search("0").isEmpty && search("-1").isEmpty && search("999").isEmpty, "zero, negative and huge numbers match nothing")
        check(search("\u{1F9EA}").isEmpty && search("\u{E9}").isEmpty, "emoji and accented queries match nothing without crashing")
        check(PeriodicTable.element(36)?.densityText == "3.749 g/L" && PeriodicTable.element(54)?.densityText == "5.894 g/L", "krypton and xenon gas densities")
        check(PeriodicTable.element(110)?.massNote == "mass number" && PeriodicTable.element(29)?.massNote == "u", "short mass note fits the detail panel")
        check(all.filter { $0.phase == .unknown }.allSatisfy { $0.number >= 100 }, "only elements 100 and up have an unknown state")

        print("\(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
