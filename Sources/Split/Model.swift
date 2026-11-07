import AppKit
import Foundation
import Kit
import SwiftUI

// MARK: - Data

struct Member: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
}

enum SplitMode: String, Codable, CaseIterable, Identifiable {
    case equal, shares, exact
    var id: Self { self }

    var label: String {
        switch self {
        case .equal: "Equally"
        case .shares: "By shares"
        case .exact: "Exact amounts"
        }
    }
}

/// One member's part of an expense: a weight (equal and shares) or an amount in major units (exact).
struct Portion: Codable, Hashable {
    var member: UUID
    var value: Decimal

    init(member: UUID, value: Decimal) {
        self.member = member
        self.value = value
    }

    enum CodingKeys: String, CodingKey { case member, value }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        member = try c.decode(UUID.self, forKey: .member)
        value = try c.decodeDecimal(.value)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(member, forKey: .member)
        try c.encode(value.description, forKey: .value)
    }
}

struct Expense: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var amount: Decimal
    var payer: UUID
    var date: Date
    var note: String = ""
    var mode: SplitMode = .equal
    var portions: [Portion]

    init(id: UUID = UUID(), title: String, amount: Decimal, payer: UUID, date: Date, note: String = "",
         mode: SplitMode = .equal, portions: [Portion]) {
        self.id = id
        self.title = title
        self.amount = amount
        self.payer = payer
        self.date = date
        self.note = note
        self.mode = mode
        self.portions = portions
    }

    enum CodingKeys: String, CodingKey { case id, title, amount, payer, date, note, mode, portions }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        amount = try c.decodeDecimal(.amount)
        payer = try c.decode(UUID.self, forKey: .payer)
        date = try c.decode(Date.self, forKey: .date)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        mode = try c.decodeIfPresent(SplitMode.self, forKey: .mode) ?? .equal
        portions = try c.decode([Portion].self, forKey: .portions)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(amount.description, forKey: .amount)
        try c.encode(payer, forKey: .payer)
        try c.encode(date, forKey: .date)
        try c.encode(note, forKey: .note)
        try c.encode(mode, forKey: .mode)
        try c.encode(portions, forKey: .portions)
    }
}

/// Money handed from one member to another to settle up.
struct Payment: Identifiable, Codable, Hashable {
    var id = UUID()
    var from: UUID
    var to: UUID
    var amount: Decimal
    var date: Date

    init(id: UUID = UUID(), from: UUID, to: UUID, amount: Decimal, date: Date) {
        self.id = id
        self.from = from
        self.to = to
        self.amount = amount
        self.date = date
    }

    enum CodingKeys: String, CodingKey { case id, from, to, amount, date }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        from = try c.decode(UUID.self, forKey: .from)
        to = try c.decode(UUID.self, forKey: .to)
        amount = try c.decodeDecimal(.amount)
        date = try c.decode(Date.self, forKey: .date)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(from, forKey: .from)
        try c.encode(to, forKey: .to)
        try c.encode(amount.description, forKey: .amount)
        try c.encode(date, forKey: .date)
    }
}

struct SplitGroup: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var currency: String
    var members: [Member]
    var expenses: [Expense] = []
    var payments: [Payment] = []

    var digits: Int { Ledger.digits(for: currency) }
    func member(_ id: UUID) -> Member? { members.first { $0.id == id } }
    func name(_ id: UUID) -> String { member(id)?.name ?? "Someone" }
    func colorIndex(_ id: UUID) -> Int { members.firstIndex { $0.id == id } ?? 0 }
    var totalMinor: Int { expenses.reduce(0) { $0 + Ledger.minor($1.amount, digits: digits) } }

    /// True when the member appears in any expense or payment, so removing them would break the books.
    func isInvolved(_ id: UUID) -> Bool {
        expenses.contains { $0.payer == id || $0.portions.contains { $0.member == id } }
            || payments.contains { $0.from == id || $0.to == id }
    }
}

extension KeyedDecodingContainer {
    /// Decimals are stored as strings so no digit is lost to Double; plain JSON numbers are accepted too.
    func decodeDecimal(_ key: Key) throws -> Decimal {
        if let s = try? decode(String.self, forKey: key), let d = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) {
            return d
        }
        return try decode(Decimal.self, forKey: key)
    }
}

// MARK: - Ledger

/// A settle-up suggestion in minor units.
struct Transfer: Hashable, Identifiable {
    var from: UUID
    var to: UUID
    var amount: Int
    var id: String { "\(from)-\(to)-\(amount)" }
}

/// The pure arithmetic: everything in integer minor units (cents), so totals always add up exactly.
enum Ledger {
    static func digits(for currency: String) -> Int {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        return f.maximumFractionDigits
    }

    static func pow10(_ n: Int) -> Decimal {
        var d: Decimal = 1
        for _ in 0..<max(0, n) { d *= 10 }
        return d
    }

    static func rounded(_ d: Decimal, _ scale: Int, _ mode: NSDecimalNumber.RoundingMode) -> Decimal {
        var input = d, out = Decimal()
        NSDecimalRound(&out, &input, scale, mode)
        return out
    }

    /// Major units to minor units, half away from zero.
    static func minor(_ d: Decimal, digits: Int) -> Int {
        NSDecimalNumber(decimal: rounded(d * pow10(digits), 0, .plain)).intValue
    }

    static func major(_ m: Int, digits: Int) -> Decimal {
        Decimal(m) / pow10(digits)
    }

    /// Deterministic 64-bit FNV-1a, so the same expense always hands its spare cents to the same people.
    static func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        // Final avalanche (MurmurHash3 fmix64), so ids that differ in one character still order randomly.
        h ^= h >> 33
        h = h &* 0xff51afd7ed558ccd
        h ^= h >> 33
        h = h &* 0xc4ceb9fe1a85ec53
        h ^= h >> 33
        return h
    }

    /// Splits `total` minor units by `weights` with the largest remainder method. The leftover units go one each
    /// to the largest fractional parts; ties are broken by a hash seeded per expense, so over many expenses
    /// nobody is always the one paying the extra cent.
    static func allocate(total: Int, weights: [(UUID, Decimal)], seed: String) -> [UUID: Int] {
        let live = weights.filter { $0.1 > 0 }
        let sum = live.reduce(Decimal(0)) { $0 + $1.1 }
        guard sum > 0, total > 0 else { return Dictionary(weights.map { ($0.0, 0) }, uniquingKeysWith: +) }
        var parts: [(id: UUID, base: Int, frac: Decimal, tie: UInt64)] = live.map { id, w in
            let exact = Decimal(total) * w / sum
            let floor = rounded(exact, 0, .down)
            return (id, NSDecimalNumber(decimal: floor).intValue, exact - floor, fnv(seed + id.uuidString))
        }
        var left = total - parts.reduce(0) { $0 + $1.base }
        let order = parts.indices.sorted { a, b in
            parts[a].frac != parts[b].frac ? parts[a].frac > parts[b].frac : parts[a].tie < parts[b].tie
        }
        var i = 0
        while left > 0 {
            parts[order[i % order.count]].base += 1
            left -= 1
            i += 1
        }
        var out = Dictionary(weights.map { ($0.0, 0) }, uniquingKeysWith: +)
        for p in parts { out[p.id, default: 0] += p.base }
        return out
    }

    /// What each participant owes for an expense, in minor units; always sums to the expense amount.
    static func shares(of e: Expense, digits: Int) -> [UUID: Int] {
        let total = minor(e.amount, digits: digits)
        let seed = e.id.uuidString
        switch e.mode {
        case .equal:
            return allocate(total: total, weights: e.portions.map { ($0.member, 1) }, seed: seed)
        case .shares:
            return allocate(total: total, weights: e.portions.map { ($0.member, $0.value) }, seed: seed)
        case .exact:
            let exact = e.portions.map { ($0.member, minor($0.value, digits: digits)) }
            if exact.reduce(0, { $0 + $1.1 }) == total {
                return Dictionary(exact, uniquingKeysWith: +)
            }
            // Amounts that no longer add up (an edited total): keep their proportions so the books still balance.
            return allocate(total: total, weights: exact.map { ($0.0, Decimal($0.1)) }, seed: seed)
        }
    }

    /// Net balance per member in minor units: positive gets money back, negative owes. Sums to zero.
    static func balances(_ g: SplitGroup) -> [UUID: Int] {
        var net = Dictionary(g.members.map { ($0.id, 0) }, uniquingKeysWith: +)
        for e in g.expenses {
            net[e.payer, default: 0] += minor(e.amount, digits: g.digits)
            for (id, owed) in shares(of: e, digits: g.digits) { net[id, default: 0] -= owed }
        }
        for p in g.payments {
            let m = minor(p.amount, digits: g.digits)
            net[p.from, default: 0] += m
            net[p.to, default: 0] -= m
        }
        return net
    }

    /// Greedy minimum cash flow: the biggest debtor pays the biggest creditor until everyone is even.
    /// Needs at most n - 1 payments. `order` breaks ties so the suggestion is stable.
    static func settle(_ net: [UUID: Int], order: [UUID]) -> [Transfer] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var bal = net
        var out: [Transfer] = []
        func pick(_ sign: Int) -> UUID? {
            bal.filter { $0.value * sign > 0 }
                .max { a, b in
                    abs(a.value) != abs(b.value) ? abs(a.value) < abs(b.value) : (rank[a.key] ?? .max) > (rank[b.key] ?? .max)
                }?.key
        }
        while let creditor = pick(1), let debtor = pick(-1) {
            let amount = min(bal[creditor]!, -bal[debtor]!)
            out.append(Transfer(from: debtor, to: creditor, amount: amount))
            bal[creditor]! -= amount
            bal[debtor]! += amount
        }
        return out
    }

    static func settle(_ g: SplitGroup) -> [Transfer] {
        settle(balances(g), order: g.members.map(\.id))
    }

    /// Lenient amount entry: "12.50", "12,50", "1,234.56", "1.234,56", "€ 7". Nil for empty, negative or junk.
    static func parseAmount(_ text: String) -> Decimal? {
        var s = text.filter { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" }
        guard !s.isEmpty, !s.contains("-") else { return nil }
        let dots = s.filter { $0 == "." }.count, commas = s.filter { $0 == "," }.count
        if dots > 0 && commas > 0 {
            let decimalSep: Character = s.lastIndex(of: ".")! > s.lastIndex(of: ",")! ? "." : ","
            s = s.filter { $0 == decimalSep || $0.isNumber }
            s = s.replacingOccurrences(of: ",", with: ".")
        } else if commas > 1 || dots > 1 {
            s = s.filter(\.isNumber)
        } else if commas == 1 {
            let after = s.split(separator: ",", omittingEmptySubsequences: false).last?.count ?? 0
            s = after == 3 ? s.replacingOccurrences(of: ",", with: "") : s.replacingOccurrences(of: ",", with: ".")
        }
        guard s.contains(where: \.isNumber), let d = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return d
    }

    /// An editable amount with the currency's fixed digits and no grouping: "148.50", "1000".
    static func plain(_ d: Decimal, digits: Int) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        f.usesGroupingSeparator = false
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "\(d)"
    }

    static func format(_ minor: Int, _ currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        return f.string(from: NSDecimalNumber(decimal: major(minor, digits: f.maximumFractionDigits))) ?? "\(minor)"
    }

    static func format(_ d: Decimal, _ currency: String) -> String {
        format(minor(d, digits: digits(for: currency)), currency)
    }
}

// MARK: - Export

enum Export {
    static func csvField(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
            ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// One row per expense and payment, with a column per member holding their share (payments: + sent, - received).
    static func csv(_ g: SplitGroup) -> String {
        let digits = g.digits
        func plain(_ m: Int) -> String { "\(Ledger.major(m, digits: digits))" }
        var rows = [(["Date", "Type", "Description", "Paid by", "Amount", "Currency", "Split"] + g.members.map(\.name))
            .map(csvField).joined(separator: ",")]
        var items: [(Date, [String])] = []
        for e in g.expenses {
            let shares = Ledger.shares(of: e, digits: digits)
            items.append((e.date, [day(e.date), "Expense", e.title, g.name(e.payer), plain(Ledger.minor(e.amount, digits: digits)),
                                   g.currency, e.mode.label] + g.members.map { shares[$0.id].map(plain) ?? "" }))
        }
        for p in g.payments {
            let m = Ledger.minor(p.amount, digits: digits)
            items.append((p.date, [day(p.date), "Payment", "\(g.name(p.from)) paid \(g.name(p.to))", g.name(p.from), plain(m),
                                   g.currency, ""] + g.members.map { $0.id == p.from ? plain(m) : $0.id == p.to ? plain(-m) : "" }))
        }
        rows += items.sorted { $0.0 < $1.0 }.map { $0.1.map(csvField).joined(separator: ",") }
        return rows.joined(separator: "\n") + "\n"
    }

    static func text(_ g: SplitGroup) -> String {
        let net = Ledger.balances(g)
        let width = g.members.map(\.name.count).max() ?? 0
        func pad(_ s: String) -> String { s + String(repeating: " ", count: max(0, width - s.count)) }
        var out = "\(g.name)\n"
        out += "\(g.expenses.count) expense\(g.expenses.count == 1 ? "" : "s"), \(Ledger.format(g.totalMinor, g.currency)) in total\n\n"
        out += "Balances\n"
        for m in g.members {
            let b = net[m.id] ?? 0
            let what = b > 0 ? "gets back \(Ledger.format(b, g.currency))" : b < 0 ? "owes \(Ledger.format(-b, g.currency))" : "settled up"
            out += "  \(pad(m.name))  \(what)\n"
        }
        let transfers = Ledger.settle(g)
        out += "\nSettle up\n"
        if transfers.isEmpty { out += "  Everyone is settled up.\n" }
        for t in transfers { out += "  \(g.name(t.from)) pays \(g.name(t.to)) \(Ledger.format(t.amount, g.currency))\n" }
        if !g.expenses.isEmpty {
            out += "\nExpenses\n"
            for e in g.expenses.sorted(by: { $0.date < $1.date }) {
                out += "  \(day(e.date))  \(e.title), \(Ledger.format(e.amount, g.currency)), paid by \(g.name(e.payer))\n"
            }
        }
        if !g.payments.isEmpty {
            out += "\nPayments\n"
            for p in g.payments.sorted(by: { $0.date < $1.date }) {
                out += "  \(day(p.date))  \(g.name(p.from)) paid \(g.name(p.to)) \(Ledger.format(p.amount, g.currency))\n"
            }
        }
        return out
    }
}

// MARK: - Model

enum Sheet: Identifiable, Hashable {
    case newGroup, editGroup(UUID), newExpense, editExpense(UUID)
    var id: Self { self }
}

@MainActor
final class SplitModel: ObservableObject {
    @Published var groups: [SplitGroup] { didSet { save() } }
    @Published var selection: SplitGroup.ID?
    @Published var selectedItem: UUID?
    @Published var sheet: Sheet?
    @Published var showBalances = true
    @Published var confirmingDelete = false
    @Published var exported: URL?
    weak var undoManager: UndoManager?
    private let persists: Bool

    static let shared = SplitModel()

    init(groups: [SplitGroup]? = nil) {
        persists = groups == nil && !Desktop.isSnapshot
        self.groups = groups ?? (Desktop.isSnapshot ? [] : Storage.load([SplitGroup].self, app: "Split", file: "groups.json") ?? [])
        selection = self.groups.first?.id
    }

    private func save() {
        guard persists else { return }
        Storage.save(groups, app: "Split", file: "groups.json")
    }

    var current: SplitGroup? { groups.first { $0.id == selection } }
    var selectedExpense: Expense? { current?.expenses.first { $0.id == selectedItem } }

    /// Applies a change with an undo step that restores the previous books.
    func change(_ action: String, _ body: (inout [SplitGroup]) -> Void) {
        let old = groups
        body(&groups)
        guard old != groups else { return }
        register(old, action)
    }

    private func register(_ old: [SplitGroup], _ action: String) {
        let um = undoManager ?? NSApp?.keyWindow?.undoManager
        um?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let now = model.groups
                model.groups = old
                if let sel = model.selection, !old.contains(where: { $0.id == sel }) { model.selection = old.first?.id }
                if model.selection == nil { model.selection = old.first?.id }
                model.register(now, action)
            }
        }
        um?.setActionName(action)
    }

    func edit(_ id: UUID?, _ action: String, _ body: (inout SplitGroup) -> Void) {
        guard let id else { return }
        change(action) { groups in
            if let i = groups.firstIndex(where: { $0.id == id }) { body(&groups[i]) }
        }
    }

    func saveGroup(_ g: SplitGroup) {
        if groups.contains(where: { $0.id == g.id }) {
            edit(g.id, "Edit Group") { $0.name = g.name; $0.currency = g.currency; $0.members = g.members }
        } else {
            change("New Group") { $0.append(g) }
            selection = g.id
        }
    }

    func deleteCurrentGroup() {
        guard let id = selection, let i = groups.firstIndex(where: { $0.id == id }) else { return }
        change("Delete Group") { $0.remove(at: i) }
        selection = groups.indices.contains(i) ? groups[i].id : groups.last?.id
    }

    func saveExpense(_ e: Expense) {
        let exists = current?.expenses.contains { $0.id == e.id } ?? false
        edit(selection, exists ? "Edit Expense" : "Add Expense") { g in
            if let i = g.expenses.firstIndex(where: { $0.id == e.id }) { g.expenses[i] = e } else { g.expenses.append(e) }
        }
        selectedItem = e.id
    }

    func deleteSelected() {
        guard let item = selectedItem else { return }
        let isPayment = current?.payments.contains { $0.id == item } ?? false
        edit(selection, isPayment ? "Delete Payment" : "Delete Expense") { g in
            g.expenses.removeAll { $0.id == item }
            g.payments.removeAll { $0.id == item }
        }
        selectedItem = nil
    }

    func markSettled(_ t: Transfer) {
        guard let g = current else { return }
        let p = Payment(from: t.from, to: t.to, amount: Ledger.major(t.amount, digits: g.digits), date: .now)
        edit(g.id, "Mark as Settled") { $0.payments.append(p) }
    }

    func editSelected() {
        if let e = selectedExpense { sheet = .editExpense(e.id) }
    }

    // MARK: Export

    func copySummary() {
        guard let g = current else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Export.text(g), forType: .string)
    }

    func export(csv: Bool) {
        guard let g = current else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [csv ? .commaSeparatedText : .plainText]
        panel.nameFieldStringValue = g.name + (csv ? ".csv" : ".txt")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (csv ? Export.csv(g) : Export.text(g)).write(to: url, atomically: true, encoding: .utf8)
            withAnimation(.snappy) { exported = url }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                if self?.exported == url { withAnimation(.snappy) { self?.exported = nil } }
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
