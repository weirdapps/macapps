import Foundation

/// `Loan --selftest`: the formulas against known values.
enum SelfTest {
    static func run() -> Int32 {
        var failures = 0, checks = 0
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failures += 1; print("FAIL: \(what)") }
        }
        func near(_ a: Double, _ b: Double, _ tol: Double = 0.005) -> Bool { abs(a - b) <= tol }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let start = utc.date(from: DateComponents(year: 2026, month: 1, day: 15))!

        // Annuity payments with published values.
        check(near(Finance.annuity(principal: 200_000, periodicRate: 0.06 / 12, periods: 360), 1199.10, 0.005), "200k at 6% over 30 years is 1199.10")
        check(near(Finance.annuity(principal: 100_000, periodicRate: 0.05 / 12, periods: 180), 790.79, 0.005), "100k at 5% over 15 years is 790.79")
        check(near(Finance.annuity(principal: 25_000, periodicRate: 0.07 / 12, periods: 60), 495.03, 0.005), "25k at 7% over 5 years is 495.03")
        check(near(Finance.annuity(principal: 12_000, periodicRate: 0, periods: 12), 1000), "0% rate divides evenly")
        check(Finance.annuity(principal: 1000, periodicRate: 0.01, periods: 0) == 0, "no periods means no payment")

        // A full 30 year schedule.
        var input = LoanInput(principal: 200_000, rate: 6, term: 30, unit: .years, start: start, frequency: .monthly, extra: 0)
        let s = Finance.schedule(input, extra: 0, calendar: utc)
        check(s.count == 360, "30 years monthly has 360 payments")
        check(s.last?.balance == 0, "balance ends at zero")
        check(near(s.reduce(0) { $0 + $1.principal }, 200_000, 0.01), "principal parts add up to the amount")
        check(near(s.reduce(0) { $0 + $1.interest }, 231_676.38, 1.0), "total interest is about 231,676")
        check(near(s[0].interest, 1000) && near(s[0].principal, 199.10), "first payment splits 1000 interest, 199.10 principal")
        check(utc.dateComponents([.year, .month], from: s[0].date) == DateComponents(year: 2026, month: 2), "first payment a month after start")
        check(utc.dateComponents([.year, .month], from: s.last!.date) == DateComponents(year: 2056, month: 1), "last payment 30 years on")
        check(s.allSatisfy { $0.balance >= 0 }, "balance never goes negative")

        // Months as the unit, and other frequencies.
        input.unit = .months; input.term = 360
        check(input.periods == 360, "360 months is 360 payments")
        input.unit = .years; input.term = 10; input.frequency = .fortnightly
        check(input.periods == 260, "10 years fortnightly is 260 payments")
        input.frequency = .quarterly
        check(Finance.schedule(input, extra: 0, calendar: utc).count == 40, "10 years quarterly is 40 payments")

        // Zero rate schedule.
        let zero = LoanInput(principal: 12_000, rate: 0, term: 12, unit: .months, start: start, frequency: .monthly, extra: 0)
        let z = Finance.schedule(zero, extra: 0, calendar: utc)
        check(z.count == 12 && z.allSatisfy { $0.interest == 0 && $0.payment == 1000 }, "0% schedule is 12 payments of 1000 with no interest")
        let zx = Finance.schedule(zero, extra: 500, calendar: utc)
        check(zx.count == 8 && zx.last?.balance == 0, "0% with 500 extra ends after 8 payments")

        // Extra payments.
        var extra = LoanInput(principal: 200_000, rate: 6, term: 30, unit: .years, start: start, frequency: .monthly, extra: 200)
        let r = Finance.loan(extra)
        check(r.schedule.count < r.baseline.count, "extra payments end the loan early")
        check(r.schedule.last?.balance == 0, "extra schedule ends at zero")
        check(r.schedule.count == 252, "200 extra a month pays off 200k at 6% in 252 payments")
        check(r.interestSaved > 79_700 && r.interestSaved < 79_900, "200 extra a month saves about 79,800 of interest")
        check(near(r.schedule.reduce(0) { $0 + $1.principal + $1.extra }, 200_000, 0.01), "principal and extra add up to the amount")
        extra.extra = 1_000_000
        check(Finance.loan(extra).schedule.count == 1, "a huge extra payment ends the loan at once")
        check(Finance.schedule(LoanInput(principal: 0), extra: 0).isEmpty, "zero amount gives no schedule")

        // Yearly grouping.
        let years = Finance.yearly(s, calendar: utc)
        check(years.count == 31 && years.first?.label == "2026", "schedule from Feb 2026 to Jan 2056 spans 31 calendar years")
        check(near(years.reduce(0) { $0 + $1.interest }, s.reduce(0) { $0 + $1.interest }, 0.05), "yearly interest adds up")

        // Savings.
        let a = SavingsInput(initial: 10_000, monthly: 0, rate: 5, years: 10, compounding: .annually)
        check(near(Finance.futureValue(a), 16_288.95, 0.01), "10k at 5% annually for 10 years is 16,288.95")
        let m = SavingsInput(initial: 10_000, monthly: 0, rate: 5, years: 10, compounding: .monthly)
        check(near(Finance.futureValue(m), 16_470.09, 0.01), "10k at 5% monthly for 10 years is 16,470.09")
        let c = SavingsInput(initial: 0, monthly: 100, rate: 6, years: 10, compounding: .monthly)
        check(near(Finance.futureValue(c), 16_387.93, 0.01), "100 a month at 6% for 10 years is 16,387.93")
        let q = SavingsInput(initial: 1_000, monthly: 0, rate: 8, years: 1, compounding: .quarterly)
        check(near(Finance.futureValue(q), 1_082.43, 0.01), "1000 at 8% quarterly for a year is 1,082.43")
        let flat = SavingsInput(initial: 1_000, monthly: 50, rate: 0, years: 2, compounding: .daily)
        check(near(Finance.futureValue(flat), 2_200), "0% savings is just the sum paid in")
        let plan = Finance.savings(c)
        check(plan.count == 11 && plan[0].balance == 0 && near(plan[10].contributed, 12_000), "savings plan has year 0 to 10")
        check(zip(plan, plan.dropFirst()).allSatisfy { $0.balance < $1.balance }, "savings balance grows every year")

        // Wording and CSV.
        check(Finance.duration(periods: 50, frequency: .monthly) == "4 years 2 months", "50 months reads 4 years 2 months")
        check(Finance.duration(periods: 12, frequency: .monthly) == "1 year", "12 months reads 1 year")
        check(Finance.duration(periods: 26, frequency: .fortnightly) == "1 year", "26 fortnights reads 1 year")
        let csv = Finance.loanCSV(Array(s.prefix(2)), timeZone: utc.timeZone).split(separator: "\n")
        check(csv.count == 3 && csv[0] == "Payment,Date,Amount,Principal,Interest,Extra,Balance", "CSV has a header and a row per payment")
        check(csv[1] == "1,2026-02-15,1199.10,199.10,1000.00,0.00,199800.90", "CSV row uses plain numbers and ISO dates")
        check(Finance.savingsCSV(plan).split(separator: "\n").count == 12, "savings CSV has a row per year")

        print(failures == 0 ? "All \(checks) checks passed." : "\(failures) of \(checks) checks failed.")
        return failures == 0 ? 0 : 1
    }
}
