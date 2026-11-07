import AppKit
import Kit
import SwiftUI

enum Theme {
    static let mint = Color(nsColor: rgb(0x3DDC97))
    static let teal = Color(nsColor: rgb(0x1E9E8A))
    static let accent = LinearGradient(colors: [mint, teal], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let owes = Color(nsColor: rgb(0xF08A3C))
    static let gets = Color(nsColor: rgb(0x1FA97F))
    static let people: [UInt32] = [0x1E9E8A, 0x5B7CF0, 0xF08A3C, 0xE0559A, 0x8B5CF6, 0x0EA5C6, 0xD9A21B, 0xE25B4B]

    static func person(_ i: Int) -> Color { Color(nsColor: rgb(people[i % people.count])) }
}

// MARK: - Root

struct ContentView: View {
    @ObservedObject var model: SplitModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            if let g = model.current {
                GroupDetail(model: model, group: g)
            } else {
                ContentUnavailableView {
                    Label("No group selected", systemImage: "person.3")
                } description: {
                    Text("Create a group for a trip or a shared flat, add who is in it, then log what everyone pays.")
                } actions: {
                    Button("New Group") { model.sheet = .newGroup }.buttonStyle(.borderedProminent).tint(Theme.teal)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 500)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.sheet = .newExpense } label: { Label("Add Expense", systemImage: "plus") }
                    .help("Add an expense (⌘N)")
                    .disabled(model.current == nil)
                Button { if let id = model.selection { model.sheet = .editGroup(id) } } label: {
                    Label("Edit Group", systemImage: "person.2")
                }
                .help("Edit the group's name, currency and members (⌘I)")
                .disabled(model.current == nil)
                Menu {
                    Button("Export Summary as Text…") { model.export(csv: false) }
                    Button("Export as CSV…") { model.export(csv: true) }
                    Divider()
                    Button("Copy Summary") { model.copySummary() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export or copy a summary")
                .disabled(model.current == nil)
                Button { withAnimation(.snappy) { model.showBalances.toggle() } } label: {
                    Label("Balances", systemImage: "sidebar.trailing")
                }
                .help(model.showBalances ? "Hide balances (⌥⌘I)" : "Show balances (⌥⌘I)")
            }
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .newGroup:
                GroupEditor(group: nil) { model.saveGroup($0) }
            case .editGroup(let id):
                if let g = model.groups.first(where: { $0.id == id }) { GroupEditor(group: g) { model.saveGroup($0) } }
            case .newExpense:
                if let g = model.current { ExpenseEditor(group: g, expense: nil) { model.saveExpense($0) } }
            case .editExpense(let id):
                if let g = model.current, let e = g.expenses.first(where: { $0.id == id }) {
                    ExpenseEditor(group: g, expense: e) { model.saveExpense($0) }
                }
            }
        }
        .confirmationDialog("Delete \(model.current?.name ?? "this group")?", isPresented: $model.confirmingDelete) {
            Button("Delete Group", role: .destructive) { model.deleteCurrentGroup() }
        } message: {
            Text("Its members, expenses and payments are removed. You can undo this.")
        }
        .overlay(alignment: .bottom) {
            if let url = model.exported {
                ExportBanner(url: url) { withAnimation(.snappy) { model.exported = nil } }
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, um in model.undoManager = um }
        .onChange(of: model.selection) { _, _ in model.selectedItem = nil }
    }
}

struct ExportBanner: View {
    let url: URL
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent).font(.system(size: 16))
            Text("Exported \(url.lastPathComponent)").font(.system(size: 13, weight: .medium))
            Button("Reveal in Finder") { revealInFinder([url]); dismiss() }.buttonStyle(.link)
            Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var model: SplitModel

    var body: some View {
        List(selection: $model.selection) {
            Section("Groups") {
                ForEach(model.groups) { g in
                    GroupRow(group: g)
                        .tag(g.id)
                        .contextMenu {
                            Button("Edit Group…") { model.sheet = .editGroup(g.id) }
                            Divider()
                            Button("Delete Group…") { model.selection = g.id; model.confirmingDelete = true }
                        }
                }
            }
        }
        .overlay {
            if model.groups.isEmpty {
                Text("No groups yet").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { model.sheet = .newGroup } label: {
                Label("New Group", systemImage: "plus.circle.fill").font(.system(size: 12.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .help("New group (⇧⌘N)")
        }
    }
}

struct GroupRow: View {
    let group: SplitGroup

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.accent)
                .frame(width: 30, height: 30)
                .overlay {
                    Text(String(group.name.prefix(1)).uppercased())
                        .font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.white)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("\(group.members.count) people · \(Ledger.format(group.totalMinor, group.currency))")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Group

struct Avatar: View {
    let name: String
    let index: Int
    var size: CGFloat = 30

    var body: some View {
        Circle()
            .fill(Theme.person(index).gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.44, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            }
    }
}

struct GroupDetail: View {
    @ObservedObject var model: SplitModel
    let group: SplitGroup

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.6)
                if group.expenses.isEmpty && group.payments.isEmpty {
                    ContentUnavailableView {
                        Label("No expenses yet", systemImage: "receipt")
                    } description: {
                        Text("Add what someone paid and choose who shares it.")
                    } actions: {
                        Button("Add Expense") { model.sheet = .newExpense }.buttonStyle(.borderedProminent).tint(Theme.teal)
                    }
                } else {
                    ActivityList(model: model, group: group)
                }
            }
            .frame(maxWidth: .infinity)
            if model.showBalances {
                Divider()
                BalancesPanel(model: model, group: group)
                    .frame(width: 300)
                    .transition(.move(edge: .trailing))
            }
        }
        .navigationTitle(group.name)
        .navigationSubtitle("\(group.members.count) people · \(group.currency)")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(group.name).font(.system(size: 24, weight: .bold, design: .rounded)).lineLimit(1)
                HStack(spacing: -7) {
                    ForEach(Array(group.members.prefix(8).enumerated()), id: \.element.id) { i, m in
                        Avatar(name: m.name, index: i, size: 24)
                            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                            .help(m.name)
                    }
                    Text(group.members.map(\.name).joined(separator: ", "))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.leading, 15)
                }
            }
            Spacer(minLength: 12)
            stat("Expenses", "\(group.expenses.count)")
            stat("Total spent", Ledger.format(group.totalMinor, group.currency), accent: true)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private func stat(_ label: String, _ value: String, accent: Bool = false) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).kerning(0.4)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(accent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
        }
        .padding(.leading, 8)
    }
}

// MARK: - Activity

struct ActivityList: View {
    @ObservedObject var model: SplitModel
    let group: SplitGroup

    private enum Item: Identifiable {
        case expense(Expense), payment(Payment)
        var id: UUID { switch self { case .expense(let e): e.id; case .payment(let p): p.id } }
        var date: Date { switch self { case .expense(let e): e.date; case .payment(let p): p.date } }
    }

    private var sections: [(String, [Item])] {
        let items = (group.expenses.map(Item.expense) + group.payments.map(Item.payment)).sorted { $0.date > $1.date }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        var out: [(String, [Item])] = []
        for item in items {
            let key = f.string(from: item.date)
            if out.last?.0 == key { out[out.count - 1].1.append(item) } else { out.append((key, [item])) }
        }
        return out
    }

    var body: some View {
        List(selection: $model.selectedItem) {
            ForEach(sections, id: \.0) { title, items in
                Section(title) {
                    ForEach(items) { item in
                        switch item {
                        case .expense(let e): ExpenseRow(group: group, expense: e).tag(e.id)
                        case .payment(let p): PaymentRow(group: group, payment: p).tag(p.id)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, group.expenses.contains(where: { $0.id == id }) {
                Button("Edit Expense…") { model.selectedItem = id; model.editSelected() }
            }
            if !ids.isEmpty {
                Button("Delete") { model.selectedItem = ids.first; model.deleteSelected() }
            }
        } primaryAction: { ids in
            if let id = ids.first { model.selectedItem = id; model.editSelected() }
        }
        .onDeleteCommand { model.deleteSelected() }
    }
}

struct ExpenseRow: View {
    let group: SplitGroup
    let expense: Expense

    private var splitText: String {
        let n = expense.portions.filter { $0.value > 0 }.count
        let everyone = n == group.members.count
        switch expense.mode {
        case .equal: return everyone ? "split equally" : "split equally among \(n)"
        case .shares: return "split by shares among \(n)"
        case .exact: return "exact amounts for \(n)"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: group.name(expense.payer), index: group.colorIndex(expense.payer), size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(expense.title.isEmpty ? "Expense" : expense.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 4) {
                    Text("\(group.name(expense.payer)) paid, \(splitText)")
                    if !expense.note.isEmpty {
                        Image(systemName: "text.bubble").help(expense.note)
                    }
                }
                .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Ledger.format(expense.amount, group.currency))
                    .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(expense.date, format: .dateTime.day().month(.abbreviated))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct PaymentRow: View {
    let group: SplitGroup
    let payment: Payment

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Theme.gets.opacity(0.14))
                .frame(width: 32, height: 32)
                .overlay { Image(systemName: "arrow.left.arrow.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.gets) }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(group.name(payment.from)) paid \(group.name(payment.to))").font(.system(size: 13, weight: .medium))
                Text("Settled up").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Ledger.format(payment.amount, group.currency))
                    .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Theme.gets)
                Text(payment.date, format: .dateTime.day().month(.abbreviated))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Balances

struct BalancesPanel: View {
    @ObservedObject var model: SplitModel
    let group: SplitGroup

    var body: some View {
        let net = Ledger.balances(group)
        let transfers = Ledger.settle(group)
        let peak = max(1, net.values.map(abs).max() ?? 1)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                title("Balances")
                VStack(spacing: 2) {
                    ForEach(Array(group.members.enumerated()), id: \.element.id) { i, m in
                        BalanceRow(name: m.name, index: i, minor: net[m.id] ?? 0, peak: peak, currency: group.currency)
                    }
                }
                title("Settle up", count: transfers.count).padding(.top, 10)
                if transfers.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 22)).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("All settled up").font(.system(size: 13, weight: .semibold))
                            Text("Nobody owes anybody.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.3)))
                } else {
                    ForEach(transfers) { t in
                        TransferCard(group: group, transfer: t) { withAnimation(.snappy) { model.markSettled(t) } }
                    }
                    Text("The fewest payments that make everyone even.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 4)
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .animation(.snappy, value: group)
    }

    private func title(_ s: String, count: Int? = nil) -> some View {
        HStack {
            Text(s).font(.system(size: 15, weight: .bold, design: .rounded))
            Spacer()
            if let count, count > 0 {
                Text("\(count) payment\(count == 1 ? "" : "s")").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }
}

struct BalanceRow: View {
    let name: String
    let index: Int
    let minor: Int
    let peak: Int
    let currency: String
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 9) {
                Avatar(name: name, index: index, size: 24)
                Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(minor == 0 ? "settled" : minor > 0 ? "gets back" : "owes")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Text(Ledger.format(abs(minor), currency))
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(minor > 0 ? Theme.gets : minor < 0 ? Theme.owes : .secondary)
                        .contentTransition(.numericText())
                }
            }
            GeometryReader { geo in
                let half = geo.size.width / 2
                let w = half * CGFloat(abs(minor)) / CGFloat(peak)
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.5))
                    Capsule()
                        .fill(minor >= 0 ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.owes.gradient))
                        .frame(width: max(w, minor == 0 ? 0 : 4))
                        .offset(x: minor >= 0 ? half : half - w)
                    Rectangle().fill(.secondary.opacity(0.5)).frame(width: 1, height: 9).offset(x: half - 0.5)
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(hovering ? 0.45 : 0)))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct TransferCard: View {
    let group: SplitGroup
    let transfer: Transfer
    let settle: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Avatar(name: group.name(transfer.from), index: group.colorIndex(transfer.from), size: 26)
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary)
                Avatar(name: group.name(transfer.to), index: group.colorIndex(transfer.to), size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(group.name(transfer.from)) pays \(group.name(transfer.to))")
                        .font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text(Ledger.format(transfer.amount, group.currency))
                        .font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
                }
                .padding(.leading, 2)
                Spacer(minLength: 0)
            }
            Button(action: settle) {
                Label("Mark as settled", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.teal)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary.opacity(hovering ? 1 : 0.6)))
        .shadow(color: .black.opacity(hovering ? 0.08 : 0.04), radius: hovering ? 6 : 3, y: 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Group editor

struct GroupEditor: View {
    let original: SplitGroup?
    let onSave: (SplitGroup) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var currency: String
    @State private var members: [Member]
    @State private var newMember = ""
    @FocusState private var addFocused: Bool

    static let currencies = ["EUR", "USD", "GBP", "CHF", "JPY", "CAD", "AUD", "NZD", "SEK", "NOK", "DKK", "PLN", "CZK",
                             "HUF", "RON", "BGN", "TRY", "ILS", "AED", "INR", "CNY", "HKD", "SGD", "KRW", "THB", "MXN", "BRL", "ZAR"]

    init(group: SplitGroup?, onSave: @escaping (SplitGroup) -> Void) {
        original = group
        self.onSave = onSave
        _name = State(initialValue: group?.name ?? "")
        _currency = State(initialValue: group?.currency ?? (Locale.current.currency?.identifier ?? "EUR"))
        _members = State(initialValue: group?.members ?? [])
    }

    private var cleanMembers: [Member] {
        members.map { Member(id: $0.id, name: $0.name.trimmingCharacters(in: .whitespaces)) }.filter { !$0.name.isEmpty }
    }
    private var valid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && cleanMembers.count >= 2 }
    private var codes: [String] { Self.currencies.contains(currency) ? Self.currencies : [currency] + Self.currencies }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Lisbon trip, Flat 3B…"))
                    Picker("Currency", selection: $currency) {
                        ForEach(codes, id: \.self) { code in
                            Text("\(code)  \(Locale.current.localizedString(forCurrencyCode: code) ?? "")").tag(code)
                        }
                    }
                }
                Section {
                    ForEach(Array(members.enumerated()), id: \.element.id) { i, m in
                        HStack(spacing: 10) {
                            Avatar(name: m.name.isEmpty ? "?" : m.name, index: i, size: 22)
                            TextField("Name", text: $members[i].name).labelsHidden()
                            Button {
                                withAnimation(.snappy) { members.removeAll { $0.id == m.id } }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .disabled(original?.isInvolved(m.id) ?? false)
                            .help(original?.isInvolved(m.id) ?? false ? "\(m.name) is part of expenses or payments" : "Remove \(m.name)")
                        }
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 18)).foregroundStyle(Theme.teal)
                            .frame(width: 22)
                        TextField("Add a person", text: $newMember, prompt: Text("Add a person")).labelsHidden().focused($addFocused).onSubmit(add)
                        Button("Add", action: add).disabled(newMember.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Members")
                } footer: {
                    Text(cleanMembers.count < 2 ? "A group needs at least two people." : "\(cleanMembers.count) people")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(original == nil ? "Create Group" : "Save") {
                    var g = original ?? SplitGroup(name: "", currency: currency, members: [])
                    g.name = name.trimmingCharacters(in: .whitespaces)
                    g.currency = currency
                    g.members = cleanMembers
                    onSave(g)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
            .padding(16)
        }
        .frame(width: 440, height: 520)
    }

    private func add() {
        let n = newMember.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        withAnimation(.snappy) { members.append(Member(name: n)) }
        newMember = ""
        addFocused = true
    }
}

// MARK: - Expense editor

struct ExpenseEditor: View {
    let group: SplitGroup
    let original: Expense?
    let onSave: (Expense) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var amountText: String
    @State private var payer: UUID
    @State private var date: Date
    @State private var note: String
    @State private var mode: SplitMode
    @State private var included: Set<UUID>
    @State private var weights: [UUID: Int]
    @State private var exactText: [UUID: String]

    init(group: SplitGroup, expense: Expense?, onSave: @escaping (Expense) -> Void) {
        self.group = group
        original = expense
        self.onSave = onSave
        let ids = group.members.map(\.id)
        _title = State(initialValue: expense?.title ?? "")
        _amountText = State(initialValue: expense.map { Ledger.plain($0.amount, digits: group.digits) } ?? "")
        _payer = State(initialValue: expense?.payer ?? ids.first ?? UUID())
        _date = State(initialValue: expense?.date ?? .now)
        _note = State(initialValue: expense?.note ?? "")
        _mode = State(initialValue: expense?.mode ?? .equal)
        let portions = expense?.portions.filter { $0.value > 0 } ?? []
        _included = State(initialValue: expense == nil ? Set(ids) : Set(portions.map(\.member)))
        var w = Dictionary(ids.map { ($0, 1) }, uniquingKeysWith: +)
        var x: [UUID: String] = [:]
        if let expense {
            for p in portions {
                if expense.mode == .shares { w[p.member] = NSDecimalNumber(decimal: p.value).intValue }
                if expense.mode == .exact { x[p.member] = Ledger.plain(p.value, digits: group.digits) }
            }
        }
        _weights = State(initialValue: w)
        _exactText = State(initialValue: x)
    }

    private var digits: Int { group.digits }
    private var amount: Decimal? { Ledger.parseAmount(amountText).map { Ledger.major(Ledger.minor($0, digits: digits), digits: digits) } }
    private var totalMinor: Int { amount.map { Ledger.minor($0, digits: digits) } ?? 0 }
    private var chosen: [Member] { group.members.filter { included.contains($0.id) } }

    private var draft: Expense {
        let portions: [Portion] = chosen.map { m in
            switch mode {
            case .equal: Portion(member: m.id, value: 1)
            case .shares: Portion(member: m.id, value: Decimal(weights[m.id] ?? 1))
            case .exact: Portion(member: m.id, value: Ledger.parseAmount(exactText[m.id] ?? "") ?? 0)
            }
        }
        return Expense(id: original?.id ?? UUID(), title: title.trimmingCharacters(in: .whitespaces), amount: amount ?? 0,
                       payer: payer, date: date, note: note.trimmingCharacters(in: .whitespacesAndNewlines), mode: mode,
                       portions: portions)
    }

    private var exactAssigned: Int {
        chosen.reduce(0) { $0 + Ledger.minor(Ledger.parseAmount(exactText[$1.id] ?? "") ?? 0, digits: digits) }
    }

    private var problem: String? {
        if totalMinor <= 0 { return "Enter an amount." }
        if chosen.isEmpty { return "Choose who shares this expense." }
        if mode == .shares && chosen.allSatisfy({ (weights[$0.id] ?? 0) == 0 }) { return "Give someone at least one share." }
        if mode == .exact {
            let left = totalMinor - exactAssigned
            if left > 0 { return "\(Ledger.format(left, group.currency)) left to assign." }
            if left < 0 { return "\(Ledger.format(-left, group.currency)) more than the total." }
        }
        return nil
    }

    var body: some View {
        let preview = totalMinor > 0 && !chosen.isEmpty ? Ledger.shares(of: draft, digits: digits) : [:]
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Description", text: $title, prompt: Text("Dinner, tickets, groceries…"))
                    TextField("Amount", text: $amountText, prompt: Text(Ledger.format(0, group.currency)))
                        .font(.system(size: 13, design: .rounded).monospacedDigit())
                    Picker("Paid by", selection: $payer) {
                        ForEach(group.members) { Text($0.name).tag($0.id) }
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }
                Section {
                    Picker("Split", selection: $mode) {
                        ForEach(SplitMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    ForEach(Array(group.members.enumerated()), id: \.element.id) { i, m in
                        memberRow(m, index: i, share: preview[m.id])
                    }
                } header: {
                    HStack {
                        Text("Split between")
                        Spacer()
                        Button(included.count == group.members.count ? "Select None" : "Select All") {
                            included = included.count == group.members.count ? [] : Set(group.members.map(\.id))
                        }
                        .buttonStyle(.link).font(.system(size: 11))
                    }
                } footer: {
                    Text(problem ?? (mode == .exact ? "Every cent is assigned." : "Spare cents rotate between people, so rounding stays fair."))
                        .font(.system(size: 11))
                        .foregroundStyle(problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.owes))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    TextField("Note", text: $note, prompt: Text("Optional"), axis: .vertical).lineLimit(2...4)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(original == nil ? "Add Expense" : "Save") { onSave(draft); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
            .padding(16)
        }
        .frame(width: 480, height: 640)
    }

    @ViewBuilder private func memberRow(_ m: Member, index: Int, share: Int?) -> some View {
        let on = included.contains(m.id)
        LabeledContent {
            if on {
                HStack(spacing: 10) {
                    switch mode {
                    case .equal:
                        EmptyView()
                    case .shares:
                        let w = weights[m.id] ?? 1
                        Text("\(w) share\(w == 1 ? "" : "s")")
                            .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                        Stepper("Shares for \(m.name)", value: Binding(get: { weights[m.id] ?? 1 }, set: { weights[m.id] = $0 }),
                                in: 0...99)
                            .labelsHidden()
                    case .exact:
                        TextField("Amount for \(m.name)", text: Binding(get: { exactText[m.id] ?? "" }, set: { exactText[m.id] = $0 }),
                                  prompt: Text(Ledger.plain(0, digits: digits)))
                            .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 90).monospacedDigit()
                    }
                    if mode != .exact {
                        Text(share.map { Ledger.format($0, group.currency) } ?? "")
                            .font(.system(size: 12.5, weight: .medium, design: .rounded)).monospacedDigit()
                            .frame(minWidth: 70, alignment: .trailing)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Toggle("Include \(m.name)", isOn: Binding(get: { on }, set: { if $0 { included.insert(m.id) } else { included.remove(m.id) } }))
                    .toggleStyle(.checkbox).labelsHidden()
                Avatar(name: m.name, index: index, size: 22).opacity(on ? 1 : 0.4)
                Text(m.name).foregroundStyle(on ? .primary : .secondary).lineLimit(1)
            }
        }
    }
}
