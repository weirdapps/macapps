import AppKit
import Kit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: InvoiceModel
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model, search: search)
                .navigationSplitViewColumnWidth(min: 230, ideal: 240, max: 320)
                .frame(minWidth: Desktop.isSnapshot ? 232 : nil)
                .searchable(text: $search, placement: .sidebar, prompt: "Search invoices")
        } detail: {
            if let i = model.selectedIndex {
                HStack(spacing: 0) {
                    Editor(model: model, invoice: $model.invoices[i])
                        .frame(minWidth: 360, idealWidth: 380, maxWidth: Desktop.isSnapshot ? 370 : 440)
                    Divider()
                    PreviewPane(model: model, invoice: model.invoices[i])
                        .frame(minWidth: 320, maxWidth: .infinity)
                }
            } else {
                ContentUnavailableView {
                    Label(model.invoices.isEmpty ? "No Invoices Yet" : "No Invoice Selected", systemImage: "doc.text")
                } description: {
                    Text(model.invoices.isEmpty ? "Make your first invoice. Your business details fill in from Settings."
                         : "Choose an invoice in the sidebar, or make a new one.")
                } actions: {
                    Button("New Invoice") { model.newInvoice() }.buttonStyle(.borderedProminent).tint(Theme.green)
                }
            }
        }
        .toolbar { Toolbar(model: model) }
        .frame(minWidth: 940, minHeight: 560)
        .tint(Theme.green)
    }
}

struct Toolbar: ToolbarContent {
    @ObservedObject var model: InvoiceModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.newInvoice() } label: { Label("New Invoice", systemImage: "square.and.pencil") }
                .help("New invoice (⌘N)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Paper", selection: $model.business.paper) {
                ForEach(Paper.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Paper size")
            Button { model.duplicate() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                .help("Duplicate invoice (⌘D)")
                .disabled(model.selected == nil)
            Button { model.togglePaid() } label: {
                Label(model.selected?.isPaid == true ? "Mark as Unpaid" : "Mark as Paid",
                      systemImage: model.selected?.isPaid == true ? "checkmark.seal.fill" : "checkmark.seal")
            }
            .help(model.selected?.isPaid == true ? "Mark as unpaid (⇧⌘P)" : "Mark as paid (⇧⌘P)")
            .disabled(model.selected == nil)
            Button { model.exportPDF() } label: { Label("Export PDF", systemImage: "square.and.arrow.up") }
                .help("Export PDF (⇧⌘E)")
                .disabled(model.selected == nil)
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var model: InvoiceModel
    let search: String

    private var shown: [Invoice] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return model.invoices.sorted { $0.created > $1.created }.filter {
            q.isEmpty || $0.number.localizedCaseInsensitiveContains(q) || $0.client.name.localizedCaseInsensitiveContains(q)
        }
    }

    private var outstanding: [(Currency, Decimal)] {
        Currency.allCases.compactMap { c in
            let sum = model.invoices.filter { !$0.isPaid && $0.currency == c }.reduce(Decimal(0)) { $0 + $1.totals.total }
            return sum > 0 ? (c, sum) : nil
        }
    }

    var body: some View {
        List(selection: $model.selection) {
            let open = shown.filter { !$0.isPaid }, paid = shown.filter(\.isPaid)
            if !open.isEmpty {
                Section("Open") { ForEach(open) { Row(invoice: $0, selected: model.selection == $0.id).tag($0.id) } }
            }
            if !paid.isEmpty {
                Section("Paid") { ForEach(paid) { Row(invoice: $0, selected: model.selection == $0.id).tag($0.id) } }
            }
        }
        .overlay {
            if shown.isEmpty, !search.isEmpty { ContentUnavailableView.search(text: search) }
        }
        .safeAreaInset(edge: .bottom) {
            if !outstanding.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Outstanding").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    ForEach(outstanding, id: \.0) { c, sum in
                        Text(Format.money(sum, c))
                            .font(.system(size: outstanding.count > 1 ? 14 : 17, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .contentTransition(.numericText())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .animation(.snappy, value: outstanding.map(\.1))
            }
        }
    }
}

struct Row: View {
    let invoice: Invoice
    var selected = false

    var body: some View {
        let status = invoice.status()
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(invoice.client.name.isEmpty ? "New client" : invoice.client.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(status.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? .white : status.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(selected ? .white.opacity(0.22) : status.color.opacity(0.14)))
                    .fixedSize()
            }
            HStack(spacing: 6) {
                Text(invoice.number).monospacedDigit().lineLimit(1)
                Spacer(minLength: 4)
                Text(Format.money(invoice.totals.total, invoice.currency)).monospacedDigit().lineLimit(1).fixedSize()
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Editor

struct Editor: View {
    @ObservedObject var model: InvoiceModel
    @Binding var invoice: Invoice

    var body: some View {
        Form {
            if model.business.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "building.2").font(.title2).foregroundStyle(Theme.gradient)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add your business details").font(.headline)
                            Text("They appear on every invoice.").foregroundStyle(.secondary)
                        }
                        Spacer()
                        SettingsLink { Text("Open Settings") }
                    }
                }
            }
            if model.sellerIsOutdated {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath").font(.title3).foregroundStyle(.secondary)
                        Text("Issued with your earlier business details.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Use Current") { model.useCurrentBusinessDetails() }
                    }
                }
            }
            Section {
                TextField("Number", text: $invoice.number)
                DatePicker("Issued", selection: $invoice.issueDate, displayedComponents: .date)
                Picker("Terms", selection: $invoice.dueDays) {
                    ForEach(DueTerms.choices + (DueTerms.choices.contains(invoice.dueDays) ? [] : [invoice.dueDays]), id: \.self) {
                        Text(DueTerms.title($0)).tag($0)
                    }
                }
                LabeledContent("Due") {
                    Text(Format.date(invoice.dueDate)).foregroundStyle(invoice.status() == .overdue ? .red : .secondary)
                }
                Picker("Currency", selection: $invoice.currency) {
                    ForEach(Currency.allCases) { Text("\($0.rawValue)  \($0.symbol)").tag($0) }
                }
            } header: {
                HStack {
                    Text("Invoice")
                    Spacer()
                    if let date = invoice.paidDate {
                        Label("Paid \(date.formatted(date: .abbreviated, time: .omitted))", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Theme.green)
                            .textCase(nil)
                    }
                }
            }

            Section {
                TextField("Name", text: $invoice.client.name)
                TextField("Address", text: $invoice.client.address, axis: .vertical).lineLimit(2...4)
                TextField("Email", text: $invoice.client.email)
                TextField("VAT ID", text: $invoice.client.vatID)
            } header: {
                HStack {
                    Text("Client")
                    Spacer()
                    let past = model.clients.filter { $0 != invoice.client }
                    if !past.isEmpty {
                        Menu("Past Clients") {
                            ForEach(past, id: \.self) { party in Button(party.name) { invoice.client = party } }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .textCase(nil)
                    }
                }
            }

            Section("Items") {
                ForEach($invoice.items) { $item in
                    ItemRow(item: $item, currency: invoice.currency) {
                        withAnimation(.snappy) { invoice.items.removeAll { $0.id == item.id } }
                    }
                }
                .onMove { invoice.items.move(fromOffsets: $0, toOffset: $1) }
                Button {
                    withAnimation(.snappy) { invoice.items.append(LineItem(vatRate: invoice.items.last?.vatRate ?? model.business.vatRate)) }
                } label: {
                    Label("Add Item", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                LabeledContent("Discount") {
                    PercentField(value: $invoice.discount)
                }
                LabeledContent("Total") {
                    Text(Format.money(invoice.totals.total, invoice.currency))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: invoice.totals.total)
                }
            }

            Section("Payment") {
                TextField("Bank", text: $invoice.bank)
                TextField("IBAN", text: $invoice.iban)
                    .overlay(alignment: .trailing) {
                        if !invoice.iban.isEmpty, !IBAN.isValid(invoice.iban) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .help("This IBAN does not pass its check digits")
                                .offset(x: 18)
                        }
                    }
                TextField("BIC", text: $invoice.bic)
                TextField("Notes", text: $invoice.notes, axis: .vertical).lineLimit(2...5)
            }
        }
        .formStyle(.grouped)
    }
}

struct ItemRow: View {
    @Binding var item: LineItem
    let currency: Currency
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Description", text: $item.description, prompt: Text("Description"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                Button(action: remove) {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove item")
                .opacity(hovering ? 1 : 0)
            }
            HStack(spacing: 6) {
                TextField("Quantity", value: $item.quantity, format: .number)
                    .labelsHidden().frame(width: 40).multilineTextAlignment(.trailing)
                Text("×").foregroundStyle(.secondary)
                TextField("Unit price", value: $item.unitPrice, format: .number.precision(.fractionLength(2)))
                    .labelsHidden().frame(width: 78).multilineTextAlignment(.trailing)
                Text("VAT").foregroundStyle(.secondary).fixedSize().padding(.leading, 4)
                PercentField(value: $item.vatRate)
                Spacer(minLength: 6)
                Text(Format.money(item.net, currency)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
        }
        .padding(.vertical, 2)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct PercentField: View {
    @Binding var value: Decimal

    var body: some View {
        HStack(spacing: 3) {
            TextField("Percent", value: $value, format: .number.precision(.fractionLength(0...2)))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 38)
            Text("%").foregroundStyle(.secondary).fixedSize()
        }
    }
}

// MARK: - Preview

struct PreviewPane: View {
    @ObservedObject var model: InvoiceModel
    let invoice: Invoice

    var body: some View {
        GeometryReader { geo in
            let paper = model.business.paper
            let scale = min((geo.size.width - 48) / paper.size.width, (geo.size.height - 40) / paper.size.height, 1.4)
            let pages = Pages.split(invoice.items).count
            ScrollView(.vertical) {
                VStack(spacing: 20) {
                    ForEach(0..<pages, id: \.self) { page in
                        InvoicePage(invoice: invoice, business: model.business, paper: paper, page: page)
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: paper.size.width * scale, height: paper.size.height * scale, alignment: .topLeading)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .animation(.snappy, value: paper)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(alignment: .bottom) {
            if let url = model.exported {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                    Text("Saved \(url.lastPathComponent)").lineLimit(1).truncationMode(.middle)
                    Button("Reveal in Finder") { revealInFinder([url]) }
                    Button { withAnimation(.snappy) { model.exported = nil } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                }
                .font(.system(size: 12))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                .padding(16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: url) {
                    try? await Task.sleep(for: .seconds(8))
                    withAnimation(.snappy) { if model.exported == url { model.exported = nil } }
                }
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var model: InvoiceModel

    var body: some View {
        Form {
            Section("Your business") {
                TextField("Name", text: $model.business.name)
                TextField("Address", text: $model.business.address, axis: .vertical).lineLimit(3...5)
                TextField("Email", text: $model.business.email)
                TextField("Phone", text: $model.business.phone)
                TextField("VAT ID", text: $model.business.vatID)
            }
            Section {
                TextField("Bank", text: $model.business.bank)
                TextField("IBAN", text: $model.business.iban)
                TextField("BIC", text: $model.business.bic)
            } header: {
                Text("Payment details")
            } footer: {
                if !model.business.iban.isEmpty, !IBAN.isValid(model.business.iban) {
                    Label("This IBAN does not pass its check digits.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text("Filled into each new invoice.").foregroundStyle(.secondary)
                }
            }
            Section("New invoices") {
                Picker("Currency", selection: $model.business.currency) {
                    ForEach(Currency.allCases) { Text("\($0.rawValue)  \($0.symbol)").tag($0) }
                }
                Picker("Terms", selection: $model.business.dueDays) {
                    ForEach(DueTerms.choices, id: \.self) { Text(DueTerms.title($0)).tag($0) }
                }
                LabeledContent("VAT rate") { PercentField(value: $model.business.vatRate) }
                Picker("Paper", selection: $model.business.paper) {
                    ForEach(Paper.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 620)
    }
}
