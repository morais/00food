import Foundation

@MainActor extension HealthEnergy {
    // Shared by the existing chart and Developer diagnostics, so both use
    // identical calorie totals, allowance rules and missing-Health fallbacks.
    func calorieHistory(profile: FoodProfile, store: FoodStore, daysIncludingToday: Int) -> [DailyCalorieBalance] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let windowStart = calendar.date(byAdding: .day, value: 1 - daysIncludingToday, to: today) ?? today
        let accountStart = calendar.startOfDay(for: store.accountStartedAt ?? today)
        let first = max(windowStart, accountStart)
        guard first <= today else { return [] }
        var foodByDay: [String: Int] = [:]
        for log in store.logs { foodByDay[log.localDate, default: 0] += log.kcal }
        var days: [DailyCalorieBalance] = []
        var date = first
        while date <= today {
            let key = FoodDates.localDate(for: date)
            let dayBudget = budget(for: profile, on: date)
            days.append(DailyCalorieBalance(date: date, eaten: foodByDay[key] ?? 0,
                                            allowance: dayBudget.allowanceKcal, tdeeKcal: dayBudget.tdeeKcal))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        return days
    }
}
