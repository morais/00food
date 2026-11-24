import Foundation

enum FoodUsageRanking {
    static func rank(_ foods: [FoodItem], logs: [FoodLog], now: Date = Date(),
                     calendar: Calendar = .current) -> [FoodItem] {
        var weightsByDay: [String: Int] = [:]
        for daysAgo in 0..<90 {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) else { continue }
            // Fixed precision keeps equal scores independent of log order.
            let weight = Int((1_000_000 * exp2(-Double(daysAgo) / 30)).rounded())
            weightsByDay[FoodDates.localDate(for: day, calendar: calendar)] = weight
        }

        var scores: [String: Int] = [:]
        for log in logs {
            guard let weight = weightsByDay[log.localDate] else { continue }
            scores[log.foodId, default: 0] += weight
        }

        return foods.filter { $0.dismissedAt == nil }.sorted { first, second in
            let firstScore = scores[first.id] ?? 0
            let secondScore = scores[second.id] ?? 0
            if firstScore != secondScore { return firstScore > secondScore }
            if first.useCount != second.useCount { return first.useCount > second.useCount }
            if first.lastUsedAt != second.lastUsedAt { return (first.lastUsedAt ?? "") > (second.lastUsedAt ?? "") }
            let nameOrder = first.name.localizedStandardCompare(second.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return first.id < second.id
        }
    }
}
