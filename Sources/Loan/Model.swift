import AppKit
import Foundation
import Kit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Inputs

enum Mode: String, CaseIterable, Codable, Identifiable {
    case loan, savings
    var id: String { rawValue }
    var title: String { self == .loan ? "Loan" : "Savings" }
}

enum Frequency: String, CaseIterable, Codable, Identifiable {
    case weekly, fortnightly, monthly, quarterly
    var id: String { rawValue }

    var perYear: Int {
        switch self {
        case .weekly: 52
        case .fortnightly: 26
        case .monthly: 12
        case .quarterly: 4
        }
    }

    var title: String { rawValue.capitalized }

    /// The date of payment number `k` (1 based), one period after the previous one.
    func date(after start: Date, periods k: Int, calendar: Calendar = .current) -> Date {
        switch self {
        case .weekly: calendar.date(byAdding: .day, value: 7 * k, to: start) ?? start
        case .fortnightly: calendar.date(byAdding: .day, value: 14 * k, to: start) ?? start
        case .monthly: calendar.date(byAdding: .month, value: k, to: start) ?? start
        case .quarterly: calendar.date(byAdding: .month, value: 3 * k, to: start) ?? start
        }
    }
}

enum TermUnit: String, CaseIterable, Codable, Identifiable {
    case years, months
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum Compounding: String, CaseIterable, Codable, Identifiable {
    case annually, quarterly, monthly, daily
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var perYear: Double {
        switch self {
        case .annually: 1
        case .quarterly: 4
        case .monthly: 12
        case .daily: 365
        }
    }
}

struct LoanInput: Codable, Equatable {
    var principal: Double = 250_000
    var rate: Double = 3.4
    var term: Int = 25
    var unit: TermUnit = .years
    var start: Date = Calendar.current.startOfDay(for: .now)
    var frequency: Frequency = .monthly
    var extra: Double = 0

    var months: Int { unit == .years ? term * 12 : term }
    var periods: Int { max(0, Int((Double(months) * Double(frequency.perYear) / 12).rounded())) }
    var periodicRate: Double { rate / 100 / Double(frequency.perYear) }
}

struct SavingsInput: Codable, Equatable {
    var initial: Double = 5_000
    var monthly: Double = 300
    var rate: Double = 4.5
    var years: Int = 20
    var compounding: Compounding = .monthly
}

// MARK: - Results

struct Payment: Identifiable, Equatable {
    let id: Int
    let date: Date
    let interest: Double
    let principal: Double
    let extra: Double
    let balance: Double
    var payment: Double { interest + principal }
    var total: Double { interest + principal + extra }
}

/// One row of the schedule table: a single payment, or the payments of one calendar year added up.
struct ScheduleRow: Identifiable {
    let id: Int
    let label: String
    let date: Date
    let payment: Double
    let principal: Double
    let interest: Double
    let extra: Double
    let balance: Double
}

struct LoanResult {
    let payment: Double
    let schedule: [Payment]
    let baseline: [Payment]

    var totalInterest: Double { schedule.reduce(0) { $0 + $1.interest } }
    var totalPaid: Double { schedule.reduce(0) { $0 + $1.total } }
    var baselineInterest: Double { baseline.reduce(0) { $0 + $1.interest } }
    var interestSaved: Double { max(0, Finance.round2(baselineInterest - totalInterest)) }
    var periodsSaved: Int { max(0, baseline.count - schedule.count) }
    var payoff: Date? { schedule.last?.date }
    var isEmpty: Bool { schedule.isEmpty }
}

struct SavingsYear: Identifiable, Equatable {
    let id: Int // Year number, 0 is today.
    let contributed: Double // Everything paid in so far, the initial amount included.
    let balance: Double
    var growth: Double { balance - contributed }
}

// MARK: - Maths

enum Finance {
    static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    /// The level payment that repays `principal` over `periods` at `periodicRate` per period (annuity formula).
    static func annuity(principal: Double, periodicRate r: Double, periods n: Int) -> Double {
        guard n > 0, principal > 0 else { return 0 }
        if r == 0 { return principal / Double(n) }
        return principal * r / (1 - pow(1 + r, -Double(n)))
    }

    /// The payment schedule, payment rounded to cents and the last payment adjusted so the balance ends at zero.
    /// `extra` goes straight to the principal with every payment and ends the loan early.
    static func schedule(_ input: LoanInput, extra: Double, calendar: Calendar = .current) -> [Payment] {
        let n = input.periods, r = input.periodicRate
        guard n > 0, input.principal > 0, input.rate >= 0 else { return [] }
        let pay = round2(annuity(principal: input.principal, periodicRate: r, periods: n))
        let extra = max(0, extra)
        var balance = round2(input.principal)
        var rows: [Payment] = []
        rows.reserveCapacity(n)
        for k in 1...n {
            let interest = round2(balance * r)
            var principal = max(0, pay - interest)
            var extraPart = extra
            if k == n || principal >= balance {
                principal = balance
                extraPart = 0
            } else if principal + extraPart >= balance {
                extraPart = balance - principal
            }
            balance = round2(balance - principal - extraPart)
            rows.append(Payment(id: k, date: input.frequency.date(after: input.start, periods: k, calendar: calendar),
                                interest: interest, principal: round2(principal), extra: round2(extraPart), balance: balance))
            if balance <= 0 { break }
        }
        return rows
    }

    static func loan(_ input: LoanInput) -> LoanResult {
        let base = schedule(input, extra: 0)
        let pay = round2(annuity(principal: input.principal, periodicRate: input.periodicRate, periods: input.periods))
        return LoanResult(payment: pay, schedule: input.extra > 0 ? schedule(input, extra: input.extra) : base, baseline: base)
    }

    /// The schedule added up by calendar year.
    static func yearly(_ schedule: [Payment], calendar: Calendar = .current) -> [ScheduleRow] {
        var rows: [ScheduleRow] = []
        var i = 0
        while i < schedule.count {
            let year = calendar.component(.year, from: schedule[i].date)
            var j = i, pay = 0.0, principal = 0.0, interest = 0.0, extra = 0.0
            while j < schedule.count, calendar.component(.year, from: schedule[j].date) == year {
                pay += schedule[j].payment; principal += schedule[j].principal
                interest += schedule[j].interest; extra += schedule[j].extra
                j += 1
            }
            rows.append(ScheduleRow(id: year, label: String(year), date: schedule[j - 1].date, payment: round2(pay),
                                    principal: round2(principal), interest: round2(interest), extra: round2(extra),
                                    balance: schedule[j - 1].balance))
            i = j
        }
        return rows
    }

    static func rows(_ schedule: [Payment]) -> [ScheduleRow] {
        schedule.map {
            ScheduleRow(id: $0.id, label: String($0.id), date: $0.date, payment: $0.payment, principal: $0.principal,
                        interest: $0.interest, extra: $0.extra, balance: $0.balance)
        }
    }

    /// The monthly rate equivalent to `annualRate` compounded `compounding.perYear` times a year.
    static func monthlyRate(annualRate: Double, compounding: Compounding) -> Double {
        let m = compounding.perYear
        return pow(1 + annualRate / 100 / m, m / 12) - 1
    }

    /// Future value with monthly contributions at the end of each month (closed form).
    static func futureValue(_ s: SavingsInput, months: Int? = nil) -> Double {
        let n = Double(months ?? s.years * 12)
        let i = monthlyRate(annualRate: s.rate, compounding: s.compounding)
        if i == 0 { return s.initial + s.monthly * n }
        let g = pow(1 + i, n)
        return s.initial * g + s.monthly * (g - 1) / i
    }

    /// Balance and contributions at the end of each year, starting with year 0.
    static func savings(_ s: SavingsInput) -> [SavingsYear] {
        guard s.years >= 0 else { return [] }
        return (0...max(0, s.years)).map { y in
            SavingsYear(id: y, contributed: s.initial + s.monthly * Double(y * 12), balance: round2(futureValue(s, months: y * 12)))
        }
    }

    /// "4 years 2 months" for a number of periods at `frequency`.
    static func duration(periods: Int, frequency: Frequency) -> String {
        let months = Int((Double(periods) * 12 / Double(frequency.perYear)).rounded())
        if months == 0 { return periods == 1 ? "1 payment" : "\(periods) payments" }
        let y = months / 12, m = months % 12
        let years = y == 0 ? nil : (y == 1 ? "1 year" : "\(y) years")
        let rest = m == 0 ? nil : (m == 1 ? "1 month" : "\(m) months")
        return [years, rest].compactMap { $0 }.joined(separator: " ")
    }

    // MARK: CSV

    static func csvNumber(_ x: Double) -> String { String(format: "%.2f", x) }

    static func loanCSV(_ schedule: [Payment], timeZone: TimeZone = .current) -> String {
        let iso = Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day()
        var lines = ["Payment,Date,Amount,Principal,Interest,Extra,Balance"]
        for p in schedule {
            lines.append([String(p.id), p.date.formatted(iso), csvNumber(p.payment), csvNumber(p.principal), csvNumber(p.interest),
                          csvNumber(p.extra), csvNumber(p.balance)].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func savingsCSV(_ years: [SavingsYear]) -> String {
        var lines = ["Year,Contributed,Growth,Balance"]
        for y in years {
            lines.append([String(y.id), csvNumber(y.contributed), csvNumber(y.growth), csvNumber(y.balance)].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Formatting

enum Fmt {
    static func euro(_ x: Double) -> String { x.formatted(.currency(code: "EUR")) }
    static func euro0(_ x: Double) -> String { x.formatted(.currency(code: "EUR").precision(.fractionLength(0))) }
    /// Short axis labels: 250k, 1.2M.
    static func compact(_ x: Double) -> String {
        let a = abs(x)
        if a >= 1_000_000 { return (x / 1_000_000).formatted(.number.precision(.fractionLength(0...1))) + "M" }
        if a >= 1_000 { return (x / 1_000).formatted(.number.precision(.fractionLength(0))) + "k" }
        return x.formatted(.number.precision(.fractionLength(0)))
    }
    static func date(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).year()) }
    static func day(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .omitted) }
}

// MARK: - App model

@MainActor
final class LoanModel: ObservableObject {
    private struct Saved: Codable {
        var mode: Mode
        var loan: LoanInput
        var savings: SavingsInput
    }

    @Published var mode: Mode { didSet { save() } }
    @Published var loan: LoanInput { didSet { if loan != oldValue { loanResult = Finance.loan(loan); save() } } }
    @Published var savings: SavingsInput {
        didSet { if savings != oldValue { savingsResult = Finance.savings(savings); save() } }
    }
    @Published var byYear = false
    @Published private(set) var loanResult: LoanResult
    @Published private(set) var savingsResult: [SavingsYear]
    private let persists: Bool

    init(mode: Mode = .loan, loan: LoanInput = LoanInput(), savings: SavingsInput = SavingsInput(), persists: Bool = true) {
        var state = Saved(mode: mode, loan: loan, savings: savings)
        if persists, !Desktop.isSnapshot, let saved = Storage.load(Saved.self, app: "Loan", file: "inputs.json") { state = saved }
        self.mode = state.mode
        self.loan = state.loan
        self.savings = state.savings
        self.persists = persists && !Desktop.isSnapshot
        loanResult = Finance.loan(state.loan)
        savingsResult = Finance.savings(state.savings)
    }

    /// Fixed figures for the website screenshot.
    static var demo: LoanModel {
        var start = DateComponents()
        start.year = 2026; start.month = 12; start.day = 1
        let loan = LoanInput(principal: 280_000, rate: 3.4, term: 25, unit: .years,
                             start: Calendar.current.date(from: start) ?? .now, frequency: .monthly, extra: 250)
        return LoanModel(mode: .loan, loan: loan, savings: SavingsInput(), persists: false)
    }

    static var demoSavings: LoanModel {
        let m = demo
        m.mode = .savings
        return m
    }

    func reset() {
        if mode == .loan { loan = LoanInput() } else { savings = SavingsInput() }
    }

    var tableRows: [ScheduleRow] { byYear ? Finance.yearly(loanResult.schedule) : Finance.rows(loanResult.schedule) }

    var canExport: Bool { mode == .loan ? !loanResult.isEmpty : !savingsResult.isEmpty }

    private func save() {
        guard persists else { return }
        Storage.save(Saved(mode: mode, loan: loan, savings: savings), app: "Loan", file: "inputs.json")
    }

    func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = mode == .loan ? "Loan schedule.csv" : "Savings plan.csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = mode == .loan ? Finance.loanCSV(loanResult.schedule) : Finance.savingsCSV(savingsResult)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            let alert = NSAlert()
            alert.messageText = "Exported \(url.lastPathComponent)"
            alert.informativeText = mode == .loan ? "\(loanResult.schedule.count) payments written as CSV."
                : "\(savingsResult.count) years written as CSV."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Reveal in Finder")
            if alert.runModal() == .alertSecondButtonReturn { revealInFinder([url]) }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
