import AppKit
import PDFKit

// `Invoice --selftest`: checks the maths, numbering, IBAN, pagination, persistence and PDF output.

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

    private static func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    static func run() -> Int32 {
        _ = NSApplication.shared

        // Line and invoice totals.
        check(LineItem(quantity: 3, unitPrice: dec("19.99")).net == dec("59.97"), "line net 3 x 19.99")
        check(LineItem(quantity: dec("0.333"), unitPrice: 10).net == dec("3.33"), "line net rounds to cents")
        check(LineItem(quantity: dec("0.125"), unitPrice: 1).net == dec("0.13"), "line net rounds half up")
        let items = [
            LineItem(quantity: 1, unitPrice: 100, vatRate: 24),
            LineItem(quantity: 2, unitPrice: 50, vatRate: 24),
            LineItem(quantity: 1, unitPrice: 10, vatRate: 13),
        ]
        let t = Totals(items: items, discount: 0)
        check(t.subtotal == 210, "subtotal 210")
        check(t.vat.count == 2 && t.vat[0].rate == 24 && t.vat[0].amount == 48 && t.vat[1].amount == dec("1.30"), "VAT grouped by rate")
        check(t.total == dec("259.30"), "total 259.30")
        let d = Totals(items: items, discount: 10)
        check(d.discount == 21 && d.net == 189, "10% discount")
        check(d.vat[0].base == 180 && d.vat[0].amount == dec("43.20"), "VAT on discounted base")
        check(d.total == dec("233.37"), "discounted total 233.37")
        let odd = Totals(items: [LineItem(quantity: 1, unitPrice: dec("33.33"), vatRate: 24),
                                 LineItem(quantity: 1, unitPrice: dec("33.33"), vatRate: 6)], discount: dec("12.5"))
        check(odd.vat.reduce(0) { $0 + $1.base } == odd.subtotal - odd.discount, "bases add up to net after discount")
        check(Totals(items: items, discount: 150).net == 0, "discount clamps at 100%")
        check(Totals(items: [], discount: 5).total == 0, "empty invoice totals zero")
        check(Totals(items: [LineItem(quantity: 1, unitPrice: dec("0.1"), vatRate: 0),
                             LineItem(quantity: 1, unitPrice: dec("0.2"), vatRate: 0)], discount: 0).total == dec("0.3"),
              "decimal sums are exact")

        // Numbering.
        check(Numbering.next(after: nil, year: 2026) == "2026-001", "first number")
        check(Numbering.next(after: "2026-014", year: 2026) == "2026-015", "increment keeps padding")
        check(Numbering.next(after: "INV-099", year: 2026) == "INV-100", "increment carries")
        check(Numbering.next(after: "INV9", year: 2026) == "INV10", "increment grows width")
        check(Numbering.next(after: "Draft", year: 2026) == "Draft-2", "number without digits")

        // IBAN.
        check(IBAN.isValid("GB82 WEST 1234 5698 7654 32"), "valid UK IBAN")
        check(IBAN.isValid("GR1601101250000000012300695"), "valid Greek IBAN")
        check(IBAN.isValid("de89370400440532013000"), "valid lowercase German IBAN")
        check(!IBAN.isValid("GB82 WEST 1234 5698 7654 33"), "wrong check digits rejected")
        check(!IBAN.isValid("12345"), "garbage rejected")
        check(IBAN.formatted("gr1601101250000000012300695") == "GR16 0110 1250 0000 0001 2300 695", "IBAN grouping")

        // Pagination.
        check(Pages.split(0) == [0..<0] && Pages.split(9) == [0..<9], "short invoices fit one page")
        check(Pages.split(12) == [0..<12, 12..<12], "totals move to a second page")
        let long = Pages.split(60)
        check(long.first == 0..<16 && long.last?.upperBound == 60 && long.last!.count <= Pages.single, "long invoice pages")
        check(long.reduce(0) { $0 + $1.count } == 60 && zip(long, long.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound },
              "pages cover every item once")

        // Status and dates.
        var inv = Invoice(number: "T-1", issueDate: Date(timeIntervalSince1970: 1_700_000_000), dueDays: 30)
        check(Calendar.current.dateComponents([.day], from: inv.issueDate, to: inv.dueDate).day == 30, "due date from terms")
        check(inv.status(now: inv.issueDate) == .due, "due before the due date")
        check(inv.status(now: inv.dueDate.addingTimeInterval(86_400 * 2)) == .overdue, "overdue after the due date")
        inv.paidDate = Date()
        check(inv.status(now: .distantFuture) == .paid, "paid wins")

        // Formatting.
        let en = Locale(identifier: "en_US")
        check(Format.money(dec("1234.5"), .eur, locale: en) == "€1,234.50", "money EUR")
        check(Format.money(dec("-3"), .gbp, locale: en).contains("£3.00"), "money GBP negative")
        check(Format.number(dec("2.5"), locale: en) == "2.5" && Format.number(4, locale: en) == "4", "quantity format")

        // Model: new, duplicate, clients, paid, persistence round trip.
        let model = InvoiceModel(invoices: [], business: Business(name: "Test", iban: "GB82WEST12345698765432", vatRate: 20), selection: nil)
        model.newInvoice()
        check(model.selected?.number == "\(Calendar.current.component(.year, from: Date()))-001", "new invoice numbered")
        check(model.selected?.iban == "GB82WEST12345698765432" && model.selected?.items.first?.vatRate == 20, "new invoice takes defaults")
        model.invoices[0].client = Party(name: "Acme")
        model.invoices[0].created = Date(timeIntervalSinceNow: -60)
        model.togglePaid()
        model.duplicate()
        check(model.invoices.count == 2 && model.selected?.client.name == "Acme" && model.selected?.isPaid == false, "duplicate copies client, unpaid")
        check(model.selected?.number.hasSuffix("-002") == true, "duplicate gets next number")
        check(Set(model.invoices.flatMap { $0.items.map(\.id) }).count == 2, "duplicate has fresh item ids")
        check(model.clients.count == 1, "past clients deduplicated")
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        model.delete(undoManager: undo)
        undo.endUndoGrouping()
        check(model.invoices.count == 1, "delete")
        undo.undo()
        check(model.invoices.count == 2, "undo delete")

        let source = InvoiceModel.demo.invoices
        let json = try? JSONEncoder().encode(source)
        let back = json.flatMap { try? JSONDecoder().decode([Invoice].self, from: $0) }
        check(back == source, "JSON round trip")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("invoice-selftest-\(UUID()).json")
        if let json { try? json.write(to: url) }
        check((try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Invoice].self, from: $0) }?.count == 6, "file round trip")
        try? FileManager.default.removeItem(at: url)

        // PDF.
        let demo = InvoiceModel.demo
        let invoice = demo.invoices.last!
        let data = PDF.data(invoice: invoice, business: demo.business)
        check(data.starts(with: Array("%PDF".utf8)), "PDF header")
        let doc = PDFDocument(data: data)
        check(doc?.pageCount == 1, "one page PDF")
        check(doc?.page(at: 0)?.bounds(for: .mediaBox).size == Paper.a4.size, "A4 media box")
        let text = doc?.string ?? ""
        check(text.contains(invoice.number) && text.contains("Lumen Coffee Roasters"), "PDF has selectable text")
        var letter = demo.business
        letter.paper = .letter
        var many = invoice
        many.items = (1...30).map { LineItem(description: "Item \($0)", quantity: 1, unitPrice: 10) }
        let multi = PDFDocument(data: PDF.data(invoice: many, business: letter))
        check(multi?.pageCount == Pages.split(30).count && multi?.page(at: 0)?.bounds(for: .mediaBox).size == Paper.letter.size,
              "multi page Letter PDF")
        check(PDF.fileName(for: invoice) == "Invoice 2026-014 Lumen Coffee Roasters.pdf", "PDF file name")

        print(failures == 0 ? "All \(checks) checks passed" : "\(failures) of \(checks) checks failed")
        return failures == 0 ? 0 : 1
    }
}
