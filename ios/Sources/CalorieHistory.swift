import Foundation

struct DailyCalorieBalance: Identifiable {
    var date: Date
    var eaten: Int
    var allowance: Int
    var id: Date { date }
}

struct CalorieBalanceAverage {
    let dayCount: Int
    let remainingKcalPerDay: Double
    let remainingPercent: Double

    static func lastSevenCompletedDays(in balances: [DailyCalorieBalance], now: Date = Date(),
                                       calendar: Calendar = .current) -> Self? {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -7, to: today) else { return nil }
        let days = balances.filter { $0.date >= start && $0.date < today && $0.allowance > 0 }
        guard !days.isEmpty else { return nil }
        let allowance = days.reduce(0.0) { $0 + Double($1.allowance) }
        let remaining = days.reduce(0.0) { $0 + Double($1.allowance - $1.eaten) }
        return Self(dayCount: days.count, remainingKcalPerDay: remaining / Double(days.count),
                    remainingPercent: remaining / allowance * 100)
    }

    var label: String {
        let prefix = "\(dayCount)-day average"
        guard remainingKcalPerDay != 0 else { return "\(prefix): on allowance (0 kcal/day · 0%)" }
        let kcal = abs(remainingKcalPerDay).formatted(.number.precision(.fractionLength(0)))
        let percent = abs(remainingPercent).formatted(.number.precision(.fractionLength(1)))
        let direction = remainingKcalPerDay < 0 ? "over allowance" : "remaining"
        return "\(prefix): \(kcal) kcal/day \(direction) (\(percent)%)"
    }
}
