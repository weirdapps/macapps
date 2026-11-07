import Foundation

/// `Split --selftest`: checks the money maths, the settle-up algorithm, export and persistence.
enum SelfTest {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    static func check(_ ok: Bool, _ name: String) {
        checks += 1
        if !ok {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    static func u(_ n: Int) -> UUID { Demo.id(n) }

    /// A small deterministic generator so the stress checks are repeatable.
    struct Rng {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    static func run() -> Int32 {
        let a = u(1), b = u(2), c = u(3), d = u(4)

        // Parsing amounts.
        check(Ledger.parseAmount("12.50") == Decimal(string: "12.5"), "parse 12.50")
        check(Ledger.parseAmount("12,50") == Decimal(string: "12.5"), "parse 12,50")
        check(Ledger.parseAmount("1,234.56") == Decimal(string: "1234.56"), "parse 1,234.56")
        check(Ledger.parseAmount("1.234,56") == Decimal(string: "1234.56"), "parse 1.234,56")
        check(Ledger.parseAmount("€ 7") == 7, "parse with a currency symbol")
        check(Ledger.parseAmount("1,500") == 1500, "parse a thousands comma")
        check(Ledger.parseAmount("") == nil && Ledger.parseAmount("abc") == nil && Ledger.parseAmount("-3") == nil,
              "reject empty, junk and negative amounts")

        // Minor units.
        check(Ledger.digits(for: "EUR") == 2 && Ledger.digits(for: "JPY") == 0, "currency fraction digits")
        check(Ledger.minor(Decimal(string: "10.005")!, digits: 2) == 1001, "round half up to cents")
        check(Ledger.minor(Decimal(string: "0.1")! + Decimal(string: "0.2")!, digits: 2) == 30, "decimal maths has no float error")
        check(Ledger.major(1234, digits: 2) == Decimal(string: "12.34"), "minor back to major")

        // Allocation.
        let thirds = Ledger.allocate(total: 1000, weights: [(a, 1), (b, 1), (c, 1)], seed: "x")
        check(thirds.values.reduce(0, +) == 1000, "equal split sums to the total")
        check(thirds.values.sorted() == [333, 333, 334], "remainder cent goes to exactly one person")
        check(Ledger.allocate(total: 1000, weights: [(a, 1), (b, 1), (c, 1)], seed: "x") == thirds, "allocation is deterministic")
        let weighted = Ledger.allocate(total: 1000, weights: [(a, 2), (b, 1), (c, 1)], seed: "y")
        check(weighted[a] == 500 && weighted[b] == 250 && weighted[c] == 250, "shares 2:1:1")
        let zero = Ledger.allocate(total: 100, weights: [(a, 1), (b, 0)], seed: "z")
        check(zero[a] == 100 && zero[b] == 0, "zero shares pay nothing")
        var extra = [a: 0, b: 0, c: 0]
        for i in 0..<300 {
            for (id, v) in Ledger.allocate(total: 100, weights: [(a, 1), (b, 1), (c, 1)], seed: "seed\(i)") where v == 34 { extra[id]! += 1 }
        }
        check(extra.values.allSatisfy { $0 > 60 && $0 < 140 }, "spare cents are spread fairly over many expenses \(extra.values.sorted())")

        // Expense shares.
        let exact = Expense(title: "Surf", amount: 180, payer: a, date: .now, mode: .exact,
                            portions: [Portion(member: b, value: 100), Portion(member: c, value: 80)])
        let es = Ledger.shares(of: exact, digits: 2)
        check(es[b] == 10000 && es[c] == 8000, "exact amounts")
        var stale = exact
        stale.amount = 90
        check(Ledger.shares(of: stale, digits: 2).values.reduce(0, +) == 9000, "exact amounts that no longer add up keep the total")
        let yen = Expense(title: "Ramen", amount: 1000, payer: a, date: .now, portions: [a, b, c].map { Portion(member: $0, value: 1) })
        check(Ledger.shares(of: yen, digits: 0).values.sorted() == [333, 333, 334], "yen have no cents")

        // Balances and settling.
        let demo = Demo.groups[0]
        let net = Ledger.balances(demo)
        check(net.values.reduce(0, +) == 0, "balances sum to zero")
        check((net[a] ?? 0) > 0 && (net[d] ?? 0) < 0, "the big payer gets money back")
        let plan = Ledger.settle(demo)
        check(plan.count <= demo.members.count - 1, "at most n - 1 payments")
        var settled = demo
        for t in plan {
            settled.payments.append(Payment(from: t.from, to: t.to, amount: Ledger.major(t.amount, digits: 2), date: .now))
        }
        check(Ledger.balances(settled).values.allSatisfy { $0 == 0 }, "marking every payment settled zeroes the books")
        check(Ledger.settle(settled).isEmpty, "nothing left to settle")

        let simple = Ledger.settle([a: 5000, b: -3000, c: -2000], order: [a, b, c])
        check(simple == [Transfer(from: b, to: a, amount: 3000), Transfer(from: c, to: a, amount: 2000)], "greedy settle picks biggest first")
        let chain = Ledger.settle([a: 1000, b: 0, c: -1000], order: [a, b, c])
        check(chain == [Transfer(from: c, to: a, amount: 1000)], "a chain collapses to one payment")

        var rng = Rng(state: 42)
        var stressOK = true
        for _ in 0..<300 {
            let n = 2 + rng.next(8)
            let ids = (0..<n).map { u(1000 + $0) }
            var bal = [UUID: Int]()
            for id in ids.dropLast() { bal[id] = rng.next(20001) - 10000 }
            bal[ids.last!] = -bal.values.reduce(0, +)
            let ts = Ledger.settle(bal, order: ids)
            var after = bal
            for t in ts {
                after[t.from]! += t.amount
                after[t.to]! -= t.amount
                if t.amount <= 0 { stressOK = false }
            }
            if !after.values.allSatisfy({ $0 == 0 }) || ts.count > n - 1 { stressOK = false }
        }
        check(stressOK, "300 random groups settle exactly in at most n - 1 payments")

        // Persistence round trip.
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("split-selftest-\(UUID()).json")
            defer { try? FileManager.default.removeItem(at: url) }
            var g = demo
            g.expenses.append(Expense(title: "Tiny", amount: Decimal(string: "0.1")!, payer: a, date: .now,
                                      portions: [Portion(member: a, value: Decimal(string: "0.3")!)]))
            try JSONEncoder().encode([g]).write(to: url)
            let back = try JSONDecoder().decode([SplitGroup].self, from: Data(contentsOf: url))
            check(back == [g], "groups survive a save and load")
            check(back[0].expenses.last?.amount == Decimal(string: "0.1"), "decimals keep every digit on disk")
        } catch {
            check(false, "persistence: \(error)")
        }

        // Export.
        check(Export.csvField("Dinner, \"big\" fish") == "\"Dinner, \"\"big\"\" fish\"", "CSV quoting")
        let csv = Export.csv(demo).split(separator: "\n")
        check(csv.count == 1 + demo.expenses.count + demo.payments.count, "CSV has a row per expense and payment")
        check(csv.first == "Date,Type,Description,Paid by,Amount,Currency,Split,Anna,Ben,Chloe,Dev", "CSV header")
        let text = Export.text(demo)
        check(text.contains("Settle up") && text.contains(" pays ") && text.contains("Lisbon trip"), "text summary")
        check(Export.text(settled).contains("Everyone is settled up."), "text summary when settled")

        print(failures == 0 ? "All \(checks) checks passed." : "\(failures) of \(checks) checks failed.")
        return failures == 0 ? 0 : 1
    }
}
