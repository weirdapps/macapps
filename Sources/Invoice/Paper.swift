import AppKit
import PDFKit
import SwiftUI

// The printed invoice: one SwiftUI view per page, drawn at PDF point size. The preview scales it, the PDF renders it.

struct InvoicePage: View {
    let invoice: Invoice
    let paper: Paper
    var page = 0
    /// Grey hints such as "Client name" for empty fields. On in the preview, off in the PDF and print.
    var placeholders = true
    /// The business details printed on this invoice: frozen at issue, otherwise the current Settings.
    private let business: Business

    init(invoice: Invoice, business: Business, paper: Paper, page: Int = 0, placeholders: Bool = true) {
        self.invoice = invoice
        self.business = invoice.issuer(business)
        self.paper = paper
        self.page = page
        self.placeholders = placeholders
    }

    private var pages: [Range<Int>] { Pages.split(invoice.items) }
    private func hint(_ value: String, _ placeholder: String) -> String {
        value.isEmpty && placeholders ? placeholder : value
    }
    private var isFirst: Bool { page == 0 }
    private var isLast: Bool { page == pages.count - 1 }
    private var ink: Color { Color(white: 0.13) }
    private var muted: Color { Color(white: 0.45) }
    private var rule: Color { Color(white: 0.87) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isFirst {
                header
                addresses.padding(.top, 26)
            } else {
                continuation
            }
            itemsTable.padding(.top, isFirst ? 26 : 18)
            if isLast {
                totals.padding(.top, 14)
            }
            Spacer(minLength: 12)
            if isLast { closing }
            footer.padding(.top, 16)
        }
        .padding(.horizontal, 46)
        .padding(.top, 46)
        .padding(.bottom, 28)
        .frame(width: paper.size.width, height: paper.size.height, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(ink)
        .environment(\.colorScheme, .light)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(business.isEmpty ? hint("", "Your Business") : business.name)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(business.isEmpty ? muted : ink)
                Group {
                    if !business.address.isEmpty { Text(business.address).lineLimit(5) }
                    if !business.email.isEmpty { Text(business.email) }
                    if !business.phone.isEmpty { Text(business.phone) }
                }
                .font(.system(size: 8.5))
                .foregroundStyle(muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("Invoice")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.green)
                Text(invoice.number).font(.system(size: 10, weight: .semibold)).monospacedDigit()
            }
        }
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.gradient).frame(height: 2) }
    }

    private var addresses: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                caption("Bill to")
                Text(hint(invoice.client.name, "Client name"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(invoice.client.name.isEmpty ? muted : ink)
                Group {
                    if !invoice.client.address.isEmpty { Text(invoice.client.address).lineLimit(6) }
                    if !invoice.client.email.isEmpty { Text(invoice.client.email) }
                    if !invoice.client.vatID.isEmpty { Text("VAT ID \(invoice.client.vatID)") }
                }
                .font(.system(size: 8.5))
                .foregroundStyle(muted)
            }
            Spacer()
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                fact("Issued", Format.date(invoice.issueDate))
                fact("Due", Format.date(invoice.dueDate))
                fact("Terms", DueTerms.title(invoice.dueDays))
                if !business.vatID.isEmpty { fact("VAT ID", business.vatID) }
            }
        }
    }

    private var continuation: some View {
        HStack {
            Text(business.isEmpty ? "Invoice" : business.name).font(.system(size: 11, weight: .bold)).lineLimit(1)
            Spacer()
            Text("Invoice \(invoice.number), continued").font(.system(size: 9)).foregroundStyle(muted)
        }
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(rule).frame(height: 1) }
    }

    private var itemsTable: some View {
        let range = pages.indices.contains(page) ? pages[page] : 0..<0
        return VStack(spacing: 0) {
            // A last page that only carries the totals gets no empty table header.
            if !range.isEmpty || isFirst { tableHeader }

            ForEach(Array(invoice.items[range].enumerated()), id: \.element.id) { offset, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(hint(item.description, "Item"))
                        .foregroundStyle(item.description.isEmpty ? muted : ink)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Format.number(item.quantity)).frame(width: 38, alignment: .trailing)
                    Text(Format.money(item.unitPrice, invoice.currency)).frame(width: 72, alignment: .trailing)
                    Text(Format.percent(item.vatRate)).foregroundStyle(muted).frame(width: 34, alignment: .trailing)
                    Text(Format.money(item.net, invoice.currency)).fontWeight(.medium).frame(width: 80, alignment: .trailing)
                }
                .font(.system(size: 9))
                .monospacedDigit()
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .overlay(alignment: .bottom) {
                    if range.lowerBound + offset < invoice.items.count - 1 { Rectangle().fill(rule).frame(height: 0.5) }
                }
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 10) {
            Text("Description").frame(maxWidth: .infinity, alignment: .leading)
            Text("Qty").frame(width: 38, alignment: .trailing)
            Text("Unit price").frame(width: 72, alignment: .trailing)
            Text("VAT").frame(width: 34, alignment: .trailing)
            Text("Amount").frame(width: 80, alignment: .trailing)
        }
        .font(.system(size: 7.5, weight: .semibold))
        .textCase(.uppercase)
        .kerning(0.5)
        .foregroundStyle(Theme.green)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.top.opacity(0.12)))
    }

    private var totals: some View {
        let t = invoice.totals
        return HStack(alignment: .center) {
            if let date = invoice.paidDate { PaidStamp(date: date).padding(.leading, 70) }
            Spacer()
            VStack(spacing: 5) {
                sum("Subtotal", t.subtotal)
                if t.discount > 0 { sum("Discount \(Format.percent(t.percent))", -t.discount) }
                ForEach(t.vat, id: \.rate) { line in
                    sum("VAT \(Format.percent(line.rate)) on \(Format.money(line.base, invoice.currency))", line.amount)
                }
                HStack {
                    Text(invoice.isPaid ? "Total paid" : "Total due").font(.system(size: 10.5, weight: .semibold))
                    Spacer()
                    Text(Format.money(t.total, invoice.currency)).font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.gradient))
                .padding(.top, 4)
            }
            .frame(width: 250)
        }
    }

    private var closing: some View {
        HStack(alignment: .top, spacing: 28) {
            if !invoice.iban.isEmpty || !invoice.bank.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    caption("Payment details")
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                        if !invoice.bank.isEmpty { fact("Bank", invoice.bank) }
                        if !invoice.iban.isEmpty { fact("IBAN", IBAN.formatted(invoice.iban)) }
                        if !invoice.bic.isEmpty { fact("BIC", invoice.bic) }
                        fact("Reference", invoice.number)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !invoice.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    caption("Notes")
                    Text(invoice.notes).font(.system(size: 8.5)).foregroundStyle(muted).lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 14)
        .overlay(alignment: .top) { Rectangle().fill(rule).frame(height: 0.5) }
    }

    private var footer: some View {
        HStack {
            Text([business.name, business.vatID.isEmpty ? "" : "VAT ID \(business.vatID)", business.email]
                .filter { !$0.isEmpty }.joined(separator: "  ·  "))
            Spacer()
            if pages.count > 1 { Text("Page \(page + 1) of \(pages.count)").monospacedDigit() }
        }
        .font(.system(size: 7))
        .foregroundStyle(muted)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 7.5, weight: .semibold)).textCase(.uppercase).kerning(0.6).foregroundStyle(Theme.green)
            .padding(.bottom, 2)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(muted)
            Text(value).fontWeight(.medium).monospacedDigit()
        }
        .font(.system(size: 8.5))
    }

    private func sum(_ label: String, _ value: Decimal) -> some View {
        HStack {
            Text(label).foregroundStyle(muted)
            Spacer()
            Text(Format.money(value, invoice.currency)).monospacedDigit()
        }
        .font(.system(size: 9))
        .padding(.horizontal, 10)
    }
}

/// A rubber stamp across the top of a paid invoice.
struct PaidStamp: View {
    let date: Date

    var body: some View {
        VStack(spacing: 1) {
            Text("Paid").font(.system(size: 26, weight: .heavy, design: .rounded)).textCase(.uppercase).kerning(3)
            Text(date.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 8, weight: .bold)).textCase(.uppercase)
        }
        .foregroundStyle(Theme.green)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.green, lineWidth: 2.5))
        .rotationEffect(.degrees(-12))
        .opacity(0.82)
    }
}

// MARK: - PDF

enum PDF {
    static func fileName(for invoice: Invoice) -> String {
        let client = invoice.client.name.trimmingCharacters(in: .whitespaces)
        let name = client.isEmpty ? "Invoice \(invoice.number)" : "Invoice \(invoice.number) \(client)"
        return name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".pdf"
    }

    /// Renders every page of the invoice to vector PDF data with ImageRenderer.
    @MainActor
    static func data(invoice: Invoice, business: Business) -> Data {
        let paper = business.paper
        let seller = invoice.issuer(business)
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: paper.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdf = CGContext(consumer: consumer, mediaBox: &box, [
                  kCGPDFContextTitle as String: "Invoice \(invoice.number)",
                  kCGPDFContextCreator as String: "Invoice",
                  kCGPDFContextAuthor as String: seller.name,
              ] as CFDictionary)
        else { return Data() }
        for page in Pages.split(invoice.items).indices {
            let renderer = ImageRenderer(content: InvoicePage(invoice: invoice, business: business, paper: paper, page: page,
                                                              placeholders: false))
            renderer.proposedSize = ProposedViewSize(paper.size)
            pdf.beginPDFPage(nil)
            renderer.render { _, draw in draw(pdf) }
            pdf.endPDFPage()
        }
        pdf.closePDF()
        return data as Data
    }

    @MainActor
    static func print(invoice: Invoice, business: Business) {
        guard let document = PDFDocument(data: data(invoice: invoice, business: business)) else { return }
        let info = NSPrintInfo.shared
        info.paperSize = business.paper.size
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        document.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: false)?
            .runModal(for: NSApp.keyWindow ?? NSWindow(), delegate: nil, didRun: nil, contextInfo: nil)
    }
}
