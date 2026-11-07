import Charts
import Kit
import SwiftUI

enum Theme {
    static let light = Color(red: 0xF7 / 255, green: 0xC5 / 255, blue: 0x48 / 255)
    static let deep = Color(red: 0xC9 / 255, green: 0x8A / 255, blue: 0x12 / 255)
    /// Gold for text: darker on light backgrounds, brighter on dark ones.
    static let ink = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0xF2 / 255, green: 0xBE / 255, blue: 0x4A / 255, alpha: 1)
            : NSColor(srgbRed: 0xA8 / 255, green: 0x6E / 255, blue: 0x08 / 255, alpha: 1)
    })
    static let gradient = LinearGradient(colors: [light, deep], startPoint: .top, endPoint: .bottom)
    static let contributions = Color(red: 0x8E / 255, green: 0x9A / 255, blue: 0xAB / 255)
}

struct ContentView: View {
    @ObservedObject var model: LoanModel

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if model.mode == .loan {
                    LoanInputs(input: $model.loan, result: model.loanResult)
                } else {
                    SavingsInputs(input: $model.savings, last: model.savingsResult.last)
                }
            }
            .frame(width: 300)
            Divider()
            Group {
                if model.mode == .loan { LoanResults(model: model) } else { SavingsResults(model: model) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .help("Switch between a loan and a savings plan")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.export() } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                    .disabled(!model.canExport)
                    .help(model.mode == .loan ? "Export the payment schedule as CSV" : "Export the savings plan as CSV")
            }
        }
        .animation(.snappy(duration: 0.25), value: model.mode)
        .onAppear {
            // The website screenshot shows no text field in edit mode.
            if Desktop.isSnapshot { DispatchQueue.main.async { NSApp.windows.forEach { $0.makeFirstResponder(nil) } } }
        }
    }
}

// MARK: - Inputs

/// A text field for a euro amount, formatted in the user's locale.
struct EuroField: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        TextField(title, value: $value, format: .currency(code: "EUR").precision(.fractionLength(0...2)))
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .onChange(of: value) { _, v in if v < 0 { value = 0 } }
    }
}

struct RateField: View {
    @Binding var value: Double

    var body: some View {
        LabeledContent("Interest rate") {
            HStack(spacing: 4) {
                TextField("Interest rate", value: $value, format: .number.precision(.fractionLength(0...3)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                Text("%").foregroundStyle(.secondary)
                Stepper("Interest rate", value: $value, in: 0...40, step: 0.1).labelsHidden()
            }
        }
        .onChange(of: value) { _, v in value = min(max(v, 0), 100) }
    }
}

struct LoanInputs: View {
    @Binding var input: LoanInput
    let result: LoanResult

    /// Switching the unit converts the term, so the loan keeps its length. Done here, not in onChange,
    /// so New Calculation (which resets the unit too) does not convert the fresh term.
    private var unit: Binding<TermUnit> {
        Binding(get: { input.unit }, set: { input.setUnit($0) })
    }

    var body: some View {
        Form {
            Section("Loan") {
                EuroField(title: "Amount", value: $input.principal)
                RateField(value: $input.rate)
                LabeledContent("Term") {
                    HStack(spacing: 6) {
                        TextField("Term", value: $input.term, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 48)
                        Stepper("Term", value: $input.term, in: 1...(input.unit == .years ? LoanInput.maxYears : LoanInput.maxMonths))
                            .labelsHidden()
                        Picker("Unit", selection: unit) {
                            ForEach(TermUnit.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                .onChange(of: input.term) { input.clampTerm() }
                DatePicker("Start date", selection: $input.start, displayedComponents: .date)
                Picker("Payments", selection: $input.frequency) {
                    ForEach(Frequency.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                EuroField(title: input.frequency == .monthly ? "Extra each month" : "Extra each payment", value: $input.extra)
            } header: {
                Text("Pay it off faster")
            } footer: {
                Text("Paid on top of every payment, straight off the balance.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !result.isEmpty {
                Section("Where the money goes") {
                    Breakdown(first: ("Amount borrowed", input.principal, Theme.contributions),
                              second: ("Interest", result.totalInterest, Theme.deep))
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct SavingsInputs: View {
    @Binding var input: SavingsInput
    let last: SavingsYear?

    var body: some View {
        Form {
            Section {
                EuroField(title: "Initial amount", value: $input.initial)
                EuroField(title: "Monthly deposit", value: $input.monthly)
                RateField(value: $input.rate)
                LabeledContent("Years") {
                    HStack(spacing: 6) {
                        TextField("Years", value: $input.years, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 48)
                        Stepper("Years", value: $input.years, in: 1...80).labelsHidden()
                    }
                }
                .onChange(of: input.years) { _, v in input.years = min(max(v, 1), 80) }
                Picker("Compounding", selection: $input.compounding) {
                    ForEach(Compounding.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Savings")
            } footer: {
                Text("Contributions are added at the end of each month.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let last, last.balance > 0 {
                Section("Where the money comes from") {
                    Breakdown(first: ("Paid in", last.contributed, Theme.contributions),
                              second: ("Growth", max(0, last.growth), Theme.deep))
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shared pieces

/// A small donut of two parts with their amounts and shares beside it.
struct Breakdown: View {
    let first: (title: String, value: Double, color: Color)
    let second: (title: String, value: Double, color: Color)

    private var total: Double { max(first.value + second.value, 0.000_001) }

    var body: some View {
        HStack(spacing: 16) {
            Chart {
                SectorMark(angle: .value("Amount", max(0, first.value)), innerRadius: .ratio(0.6), angularInset: 1.5)
                    .foregroundStyle(first.color.opacity(0.75))
                    .cornerRadius(3)
                SectorMark(angle: .value("Amount", max(0, second.value)), innerRadius: .ratio(0.6), angularInset: 1.5)
                    .foregroundStyle(Theme.gradient)
                    .cornerRadius(3)
            }
            .chartLegend(.hidden)
            .frame(width: 78, height: 78)
            .overlay {
                Text((second.value / total).formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
            }
            VStack(alignment: .leading, spacing: 10) {
                row(first, swatch: AnyShapeStyle(first.color.opacity(0.75)))
                row(second, swatch: AnyShapeStyle(Theme.gradient))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .animation(.snappy, value: second.value)
    }

    private func row(_ part: (title: String, value: Double, color: Color), swatch: AnyShapeStyle) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(part.title).font(.system(size: 11.5)).foregroundStyle(.secondary)
                Text(Fmt.euro0(part.value))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: part.value))
            }
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary.opacity(0.8)))
    }
}

struct Hero: View {
    let title: String
    let value: Double
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text(Fmt.euro(value))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(LinearGradient(colors: [Theme.deep, Theme.ink], startPoint: .top, endPoint: .bottom))
                .contentTransition(.numericText(value: value))
                .animation(.snappy, value: value)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(note).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Theme.light.opacity(0.28), Theme.deep.opacity(0.12)], startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.deep.opacity(0.25)))
    }
}

struct Stat: View {
    let title: String
    let value: String
    var note: String? = nil
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(note ?? " ").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.quaternary.opacity(hovering ? 0.55 : 0.32)))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct LegendDot: View {
    let color: Color
    let title: String
    var dashed = false

    var body: some View {
        HStack(spacing: 5) {
            if dashed {
                Capsule().strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])).frame(width: 14, height: 4)
            } else {
                Capsule().fill(color).frame(width: 14, height: 4)
            }
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Loan results

struct LoanResults: View {
    @ObservedObject var model: LoanModel

    private var result: LoanResult { model.loanResult }
    private var input: LoanInput { model.loan }

    var body: some View {
        if result.isEmpty {
            ContentUnavailableView("Nothing to work out yet", systemImage: "house",
                                   description: Text("Enter an amount and a term to see the payments."))
        } else {
            VStack(spacing: 12) {
                summary
                if input.extra > 0, result.periodsSaved > 0 { savingsBanner }
                chart
                schedule
            }
            .padding(16)
        }
    }

    private var paymentTitle: String {
        switch input.frequency {
        case .weekly: "Weekly payment"
        case .fortnightly: "Fortnightly payment"
        case .monthly: "Monthly payment"
        case .quarterly: "Quarterly payment"
        }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            Hero(title: paymentTitle, value: result.payment + input.extra,
                 note: input.extra > 0 ? "\(Fmt.euro(result.payment)) plus \(Fmt.euroAuto(input.extra)) extra"
                     : "\(result.schedule.count) payments")
                .frame(width: 250)
            Stat(title: "Total interest", value: Fmt.euro0(result.totalInterest),
                 note: "\(Int((result.totalInterest / max(input.principal, 1) * 100).rounded()))% of the amount")
            Stat(title: "Total paid", value: Fmt.euro0(result.totalPaid), note: "\(result.schedule.count) payments")
            Stat(title: "Paid off", value: result.payoff.map(Fmt.date) ?? "", note: Finance.duration(
                periods: result.schedule.count, frequency: input.frequency))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var savingsBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.gradient))
            bannerText
                .font(.system(size: 13))
                .lineLimit(2)
            Spacer()
            Text("Without extra: \(Fmt.date(result.baseline.last?.date ?? .now))")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.light.opacity(0.14)))
    }

    private var bannerText: Text {
        let time = Text(Finance.duration(periods: result.periodsSaved, frequency: input.frequency)).bold().foregroundColor(Theme.ink)
        let extra = Text("Paying \(Fmt.euroAuto(input.extra)) extra ")
        // At 0% there is no interest to save, only time.
        guard result.interestSaved >= 1 else { return extra + Text("pays it off ") + time + Text(" sooner.") }
        return extra + Text("saves ") + Text(Fmt.euro0(result.interestSaved)).bold().foregroundColor(Theme.ink)
            + Text(" in interest and ") + time + Text(".")
    }

    private var chart: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Balance over time").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    LegendDot(color: Theme.deep, title: input.extra > 0 ? "With extra" : "Balance")
                    if input.extra > 0 { LegendDot(color: .secondary, title: "Without extra", dashed: true) }
                }
                Chart {
                    if input.extra > 0 {
                        ForEach(result.baseline) { p in
                            LineMark(x: .value("Date", p.date), y: .value("Balance", p.balance), series: .value("Series", "Without"))
                                .foregroundStyle(Color.secondary.opacity(0.7))
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        }
                    }
                    ForEach(result.schedule) { p in
                        AreaMark(x: .value("Date", p.date), y: .value("Balance", p.balance))
                            .foregroundStyle(LinearGradient(colors: [Theme.light.opacity(0.45), Theme.light.opacity(0.04)],
                                                            startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Date", p.date), y: .value("Balance", p.balance), series: .value("Series", "With"))
                            .foregroundStyle(Theme.deep)
                            .lineStyle(StrokeStyle(lineWidth: 2.2))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { v in
                        AxisGridLine()
                        AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.compact(d)) } }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.year())
                    }
                }
            }
        }
        .frame(height: 200)
    }

    private var schedule: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Schedule").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Picker("Rows", selection: $model.byYear) {
                        Text("Payments").tag(false)
                        Text("Years").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)
                    .help("Show every payment, or each calendar year added up")
                }
                ScheduleTable(rows: model.tableRows, byYear: model.byYear)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct ScheduleTable: View {
    let rows: [ScheduleRow]
    let byYear: Bool

    var body: some View {
        Table(rows) {
            TableColumn(byYear ? "Year" : "#") { r in Text(r.label).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 40, ideal: 50, max: 70)
            TableColumn(byYear ? "Last payment" : "Date") { r in Text(Fmt.day(r.date)).monospacedDigit() }
                .width(min: 90, ideal: 110)
            TableColumn("Payment") { r in amount(r.payment + r.extra) }
            TableColumn("Principal") { r in amount(r.principal + r.extra) }
            TableColumn("Interest") { r in amount(r.interest) }
            TableColumn("Balance") { r in amount(r.balance).fontWeight(.medium) }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    private func amount(_ x: Double) -> Text {
        Text(Fmt.euro(x)).monospacedDigit()
    }
}

// MARK: - Savings results

struct SavingsResults: View {
    @ObservedObject var model: LoanModel

    private var years: [SavingsYear] { model.savingsResult }
    private var input: SavingsInput { model.savings }

    var body: some View {
        if let last = years.last {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Hero(title: "Future value", value: last.balance, note: "After \(input.years) \(input.years == 1 ? "year" : "years")")
                        .frame(width: 250)
                    Stat(title: "You put in", value: Fmt.euro0(last.contributed),
                         note: input.monthly > 0 ? "\(Fmt.euroAuto(input.monthly)) a month"
                             : "A single deposit")
                    Stat(title: "Growth", value: Fmt.euro0(last.growth),
                         note: last.balance > 0 ? "\(Int((last.growth / last.balance * 100).rounded()))% of the total" : nil)
                    Stat(title: "Effective rate", value: effectiveRate, note: "\(input.compounding.title) compounding")
                }
                .fixedSize(horizontal: false, vertical: true)
                chart
                table
            }
            .padding(16)
        } else {
            ContentUnavailableView("Nothing to work out yet", systemImage: "banknote",
                                   description: Text("Enter an amount, a rate and a number of years."))
        }
    }

    private var effectiveRate: String {
        let monthly = Finance.monthlyRate(annualRate: input.rate, compounding: input.compounding)
        let annual = pow(1 + monthly, 12) - 1
        return (annual).formatted(.percent.precision(.fractionLength(2)))
    }

    private var chart: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Contributions and growth").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    LegendDot(color: Theme.contributions, title: "Contributions")
                    LegendDot(color: Theme.deep, title: "Growth")
                }
                Chart {
                    ForEach(years) { y in
                        AreaMark(x: .value("Year", y.id), y: .value("Amount", y.contributed), stacking: .standard)
                            .foregroundStyle(by: .value("Part", "Contributions"))
                        AreaMark(x: .value("Year", y.id), y: .value("Amount", max(0, y.growth)), stacking: .standard)
                            .foregroundStyle(by: .value("Part", "Growth"))
                    }
                }
                .chartForegroundStyleScale([
                    "Contributions": AnyShapeStyle(LinearGradient(colors: [Theme.contributions.opacity(0.55), Theme.contributions.opacity(0.35)],
                                                                  startPoint: .top, endPoint: .bottom)),
                    "Growth": AnyShapeStyle(LinearGradient(colors: [Theme.light, Theme.deep.opacity(0.8)],
                                                           startPoint: .top, endPoint: .bottom)),
                ])
                .chartLegend(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) { v in
                        AxisGridLine()
                        AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.compact(d)) } }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 8)) { v in
                        AxisGridLine()
                        AxisValueLabel { if let y = v.as(Int.self) { Text("Year \(y)") } }
                    }
                }
                .chartXScale(domain: 0...max(1, input.years))
            }
        }
        .frame(height: 230)
    }

    private var table: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Year by year").font(.system(size: 13, weight: .semibold))
                Table(Array(years.dropFirst())) {
                    TableColumn("Year") { y in Text(String(y.id)).monospacedDigit().foregroundStyle(.secondary) }
                        .width(min: 40, ideal: 50, max: 70)
                    TableColumn("Contributed") { y in Text(Fmt.euro(y.contributed)).monospacedDigit() }
                    TableColumn("Growth") { y in Text(Fmt.euro(y.growth)).monospacedDigit().foregroundStyle(Theme.ink) }
                    TableColumn("Balance") { y in Text(Fmt.euro(y.balance)).monospacedDigit().fontWeight(.medium) }
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .frame(maxHeight: .infinity)
    }
}
