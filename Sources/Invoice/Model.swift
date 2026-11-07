import AppKit
import Kit
import SwiftUI

// MARK: - Values

enum Currency: String, Codable, CaseIterable, Identifiable {
    case eur = "EUR", usd = "USD", gbp = "GBP"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .eur: "€"
        case .usd: "$"
        case .gbp: "£"
        }
    }
}

enum Paper: String, Codable, CaseIterable, Identifiable {
    case a4, letter
    var id: String { rawValue }
    var title: String { self == .a4 ? "A4" : "Letter" }
    /// Page size in PDF points.
    var size: CGSize { self == .a4 ? CGSize(width: 595, height: 842) : CGSize(width: 612, height: 792) }
}

enum DueTerms {
    static let choices = [0, 7, 14, 30, 45, 60]
    static func title(_ days: Int) -> String { days == 0 ? "Due on receipt" : "Net \(days) days" }
}

struct Party: Codable, Hashable {
    var name = ""
    var address = ""
    var email = ""
    var vatID = ""
}

struct Business: Codable, Equatable {
    var name = ""
    var address = ""
    var email = ""
    var phone = ""
    var vatID = ""
    var bank = ""
    var iban = ""
    var bic = ""
    var currency = Currency.eur
    var paper = Paper.a4
    var dueDays = 30
    var vatRate: Decimal = 24

    var isEmpty: Bool { name.trimmingCharacters(in: .whitespaces).isEmpty }
}

struct LineItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var description = ""
    var quantity: Decimal = 1
    var unitPrice: Decimal = 0
    /// Percent, for example 24 for 24%.
    var vatRate: Decimal = 24

    var net: Decimal { (quantity * unitPrice).rounded(2) }
}

struct Invoice: Codable, Identifiable, Hashable {
    var id = UUID()
    var number = ""
    var issueDate = Date()
    var dueDays = 30
    var client = Party()
    var items: [LineItem] = []
    /// Percent off the subtotal.
    var discount: Decimal = 0
    var currency = Currency.eur
    var notes = ""
    var bank = ""
    var iban = ""
    var bic = ""
    var paidDate: Date?
    var created = Date()

    var isPaid: Bool { paidDate != nil }
    var dueDate: Date { Calendar.current.date(byAdding: .day, value: dueDays, to: issueDate) ?? issueDate }
    var totals: Totals { Totals(items: items, discount: discount) }

    func status(now: Date = Date()) -> Status {
        if isPaid { return .paid }
        return Calendar.current.startOfDay(for: now) > Calendar.current.startOfDay(for: dueDate) ? .overdue : .due
    }
}

enum Status {
    case paid, due, overdue
    var title: String {
        switch self {
        case .paid: "Paid"
        case .due: "Due"
        case .overdue: "Overdue"
        }
    }
    var color: Color {
        switch self {
        case .paid: Theme.green
        case .due: .orange
        case .overdue: .red
        }
    }
}

// MARK: - Maths

extension Decimal {
    func rounded(_ scale: Int) -> Decimal {
        var value = self, result = Decimal()
        NSDecimalRound(&result, &value, scale, .plain)
        return result
    }
}

/// Invoice totals in exact decimal arithmetic. The discount is spread over each VAT rate so the bases add up to
/// subtotal minus discount to the cent, and VAT is charged on the discounted base.
struct Totals: Equatable {
    struct VATLine: Equatable {
        var rate: Decimal
        var base: Decimal
        var amount: Decimal
    }

    var subtotal: Decimal = 0
    var discount: Decimal = 0
    var vat: [VATLine] = []

    var net: Decimal { subtotal - discount }
    var vatTotal: Decimal { vat.reduce(0) { $0 + $1.amount } }
    var total: Decimal { net + vatTotal }

    init(items: [LineItem], discount percent: Decimal) {
        let pct = Swift.min(Swift.max(percent, 0), 100)
        var byRate: [Decimal: Decimal] = [:]
        for item in items { byRate[item.vatRate, default: 0] += item.net }
        subtotal = byRate.values.reduce(0, +)
        for rate in byRate.keys.sorted(by: >) {
            let gross = byRate[rate]!
            let off = (gross * pct / 100).rounded(2)
            discount += off
            let base = gross - off
            vat.append(VATLine(rate: rate, base: base, amount: (base * rate / 100).rounded(2)))
        }
    }
}

enum Numbering {
    /// The next invoice number after `last`: its trailing digits plus one, zero padding and prefix kept
    /// ("2026-014" gives "2026-015", "INV9" gives "INV10"). With no previous invoice, "<year>-001".
    static func next(after last: String?, year: Int) -> String {
        guard let last, !last.isEmpty else { return String(format: "%d-001", year) }
        let digits = String(last.reversed().prefix { $0.isNumber }.reversed())
        guard !digits.isEmpty, let n = Int(digits) else { return last + "-2" }
        let prefix = String(last.dropLast(digits.count))
        let next = String(n + 1)
        return prefix + String(repeating: "0", count: max(0, digits.count - next.count)) + next
    }
}

enum IBAN {
    static func compact(_ s: String) -> String { s.uppercased().filter { $0.isLetter || $0.isNumber } }

    /// Groups of four, as printed on paper.
    static func formatted(_ s: String) -> String {
        let c = Array(compact(s))
        return stride(from: 0, to: c.count, by: 4).map { String(c[$0..<min($0 + 4, c.count)]) }.joined(separator: " ")
    }

    /// The ISO 13616 mod 97 check.
    static func isValid(_ s: String) -> Bool {
        let c = compact(s)
        guard c.count >= 15, c.count <= 34, c.prefix(2).allSatisfy(\.isLetter), c.dropFirst(2).prefix(2).allSatisfy(\.isNumber)
        else { return false }
        var remainder = 0
        for ch in c.dropFirst(4) + c.prefix(4) {
            let value: Int
            if let d = ch.wholeNumberValue { value = d } else if let a = ch.asciiValue, ch.isLetter { value = Int(a) - 55 } else { return false }
            for digit in String(value) { remainder = (remainder * 10 + Int(String(digit))!) % 97 }
        }
        return remainder == 1
    }
}

enum Pages {
    static let single = 9, first = 16, middle = 22

    /// Splits `count` line items over pages: the first page carries the header, the last the totals and payment block.
    static func split(_ count: Int) -> [Range<Int>] {
        if count <= single { return [0..<count] }
        var pages: [Range<Int>] = []
        var start = 0
        while count - start > single {
            let take = min(pages.isEmpty ? first : middle, count - start)
            pages.append(start..<(start + take))
            start += take
        }
        pages.append(start..<count)
        return pages
    }
}

enum Format {
    static func money(_ value: Decimal, _ currency: Currency, locale: Locale = .current) -> String {
        value.formatted(.currency(code: currency.rawValue).locale(locale))
    }

    static func number(_ value: Decimal, locale: Locale = .current) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).locale(locale))
    }

    static func percent(_ value: Decimal) -> String { number(value) + "%" }

    static func date(_ date: Date) -> String { date.formatted(date: .long, time: .omitted) }
}

enum Theme {
    static let top = Color(red: 0x2E / 255, green: 0xCC / 255, blue: 0x8F / 255)
    static let green = Color(red: 0x0F / 255, green: 0x7A / 255, blue: 0x55 / 255)
    static let gradient = LinearGradient(colors: [top, green], startPoint: .top, endPoint: .bottom)
}

// MARK: - Store

@MainActor
final class InvoiceModel: ObservableObject {
    @Published var invoices: [Invoice] { didSet { save() } }
    @Published var business: Business { didSet { saveBusiness() } }
    @Published var selection: Invoice.ID?
    @Published var exported: URL?
    private let persists: Bool

    init() {
        persists = !Desktop.isSnapshot
        invoices = Storage.load([Invoice].self, app: "Invoice", file: "invoices.json") ?? []
        business = Storage.load(Business.self, app: "Invoice", file: "business.json") ?? Business()
        selection = invoices.sorted { $0.created > $1.created }.first?.id
    }

    init(invoices: [Invoice], business: Business, selection: Invoice.ID?) {
        persists = false
        self.invoices = invoices
        self.business = business
        self.selection = selection
    }

    var selectedIndex: Int? { invoices.firstIndex { $0.id == selection } }
    var selected: Invoice? { selectedIndex.map { invoices[$0] } }

    /// Past clients, newest first, one per name.
    var clients: [Party] {
        var seen = Set<String>()
        return invoices.sorted { $0.created > $1.created }.map(\.client).filter {
            let key = $0.name.trimmingCharacters(in: .whitespaces).lowercased()
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    var nextNumber: String {
        let last = invoices.max { $0.created < $1.created }?.number
        var number = Numbering.next(after: last, year: Calendar.current.component(.year, from: Date()))
        let used = Set(invoices.map(\.number))
        while used.contains(number) { number = Numbering.next(after: number, year: 0) }
        return number
    }

    func newInvoice() {
        var invoice = Invoice()
        invoice.number = nextNumber
        invoice.dueDays = business.dueDays
        invoice.currency = business.currency
        invoice.bank = business.bank
        invoice.iban = business.iban
        invoice.bic = business.bic
        invoice.items = [LineItem(vatRate: business.vatRate)]
        invoices.append(invoice)
        selection = invoice.id
    }

    func duplicate() {
        guard var copy = selected else { return }
        copy.id = UUID()
        copy.items = copy.items.map { var item = $0; item.id = UUID(); return item }
        copy.number = nextNumber
        copy.issueDate = Date()
        copy.created = Date()
        copy.paidDate = nil
        invoices.append(copy)
        selection = copy.id
    }

    func togglePaid() {
        guard let i = selectedIndex else { return }
        invoices[i].paidDate = invoices[i].isPaid ? nil : Date()
    }

    func delete(undoManager: UndoManager?) {
        guard let i = selectedIndex else { return }
        let removed = invoices.remove(at: i)
        selection = invoices.sorted { $0.created > $1.created }.first?.id
        undoManager?.registerUndo(withTarget: self) { model in
            model.invoices.insert(removed, at: min(i, model.invoices.count))
            model.selection = removed.id
        }
        undoManager?.setActionName("Delete Invoice")
    }

    private func save() {
        guard persists else { return }
        Storage.save(invoices, app: "Invoice", file: "invoices.json")
    }

    private func saveBusiness() {
        guard persists else { return }
        Storage.save(business, app: "Invoice", file: "business.json")
    }

    // MARK: Export

    func exportPDF() {
        guard let invoice = selected else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = PDF.fileName(for: invoice)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PDF.data(invoice: invoice, business: business).write(to: url, options: .atomic)
            withAnimation(.snappy) { exported = url }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func print() {
        guard let invoice = selected else { return }
        PDF.print(invoice: invoice, business: business)
    }
}

// MARK: - Demo

extension InvoiceModel {
    static var demo: InvoiceModel {
        let business = Business(name: "Northwind Studio", address: "14 Harbour Lane\nBrighton BN1 1AA\nUnited Kingdom",
                                email: "hello@northwind.studio", phone: "+44 1273 555 014", vatID: "GB 123 4567 89",
                                bank: "Harbour Bank", iban: "GB82 WEST 1234 5698 7654 32", bic: "WESTGB2L",
                                currency: .eur, paper: .a4, dueDays: 30, vatRate: 20)
        let cal = Calendar.current
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date()))! }
        func invoice(_ n: String, _ client: Party, _ issued: Int, _ items: [LineItem], paid: Bool = false,
                     discount: Decimal = 0, currency: Currency = .eur, terms: Int = 30) -> Invoice {
            Invoice(number: n, issueDate: day(issued), dueDays: terms, client: client, items: items, discount: discount,
                    currency: currency, notes: "Thank you for your business. Please quote the invoice number with your payment.",
                    bank: business.bank, iban: business.iban, bic: business.bic, paidDate: paid ? day(issued + 12) : nil,
                    created: day(issued))
        }
        let acme = Party(name: "Lumen Coffee Roasters", address: "Kifisias 112\n115 26 Athens\nGreece",
                         email: "accounts@lumencoffee.gr", vatID: "EL 099 887 766")
        let fjord = Party(name: "Fjord Outdoor AS", address: "Strandgata 9\n5013 Bergen\nNorway", email: "ap@fjord.no", vatID: "NO 912 345 678")
        let bloom = Party(name: "Bloom & Co", address: "220 Market Street\nSan Francisco, CA 94105", email: "billing@bloom.co")
        let atlas = Party(name: "Atlas Publishing", address: "3 Rue Oberkampf\n75011 Paris\nFrance", email: "compta@atlas.fr", vatID: "FR 40 303 265 045")
        let invoices = [
            invoice("2026-009", atlas, -96, [LineItem(description: "Cover illustration", quantity: 1, unitPrice: 1200, vatRate: 20)], paid: true),
            invoice("2026-010", bloom, -70, [LineItem(description: "Landing page design", quantity: 1, unitPrice: 2800, vatRate: 0)],
                    paid: true, currency: .usd),
            invoice("2026-011", fjord, -48, [LineItem(description: "Catalogue layout, 48 pages", quantity: 48, unitPrice: 65, vatRate: 0)]),
            invoice("2026-012", atlas, -31, [LineItem(description: "Typesetting, spring titles", quantity: 6, unitPrice: 340, vatRate: 20)],
                    paid: true),
            invoice("2026-013", bloom, -9, [LineItem(description: "Monthly retainer, October", quantity: 1, unitPrice: 3200, vatRate: 0)],
                    currency: .usd, terms: 14),
            invoice("2026-014", acme, -2, [
                LineItem(description: "Brand identity: logo, palette and type system", quantity: 1, unitPrice: 2400, vatRate: 24),
                LineItem(description: "Packaging design, three coffee blends", quantity: 3, unitPrice: 450, vatRate: 24),
                LineItem(description: "Product photography, half day", quantity: 4, unitPrice: 95, vatRate: 24),
                LineItem(description: "Printed sample boxes", quantity: 25, unitPrice: Decimal(string: "6.40")!, vatRate: 13),
            ], discount: 5),
        ]
        return InvoiceModel(invoices: invoices, business: business, selection: invoices.last!.id)
    }
}
