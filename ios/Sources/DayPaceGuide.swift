import SwiftUI

struct DayPaceGuide: View {
    let baseKcal: Int
    let activeKcal: Int
    let eatenKcal: Int
    let logs: [FoodLog]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let pace = DayPace(baseKcal: baseKcal, activeKcal: activeKcal,
                               eatenKcal: eatenKcal, logs: logs, now: timeline.date)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Day pace").font(.caption.weight(.semibold))
                    Spacer()
                    Text(pace.usesRecentLogs ? "Your recent timing" : "Loose daytime guide")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                GeometryReader { geometry in
                    let width = geometry.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary).frame(height: 10)
                        Capsule().fill(.tint).frame(width: width * pace.usedFraction, height: 10)
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(.secondary.opacity(0.7), lineWidth: 1.5)
                            .frame(width: max(8, width * (pace.upperFraction - pace.lowerFraction)), height: 17)
                            .offset(x: width * pace.lowerFraction)
                    }
                    .frame(height: 17)
                }
                .frame(height: 17)
                HStack {
                    Text("\(pace.usedPercent)% used")
                    Spacer()
                    Text("~\(pace.lowerKcal)–\(pace.upperKcal) kcal by now")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint("A loose timing guide. Active calories widen the upper edge without setting a minimum to eat.")
        }
    }
}

private struct DayPace {
    let lowerKcal: Int
    let upperKcal: Int
    let lowerFraction: Double
    let upperFraction: Double
    let usedFraction: Double
    let usedPercent: Int
    let usesRecentLogs: Bool

    init(baseKcal: Int, activeKcal: Int, eatenKcal: Int, logs: [FoodLog], now: Date) {
        let base = max(1, baseKcal)
        let active = max(0, activeKcal)
        let allowance = base + active
        let clock = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minute = (clock.hour ?? 0) * 60 + (clock.minute ?? 0)
        let learned = Self.recentMealFraction(logs: logs, at: minute, now: now)
        usesRecentLogs = learned != nil
        let daytimeFraction = min(1, max(0, Double(minute - 7 * 60) / Double(16 * 60)))
        let center = learned ?? daytimeFraction
        // A wide range makes room for meals rather than implying a steady burn rate.
        lowerKcal = Int((Double(base) * max(0, center - 0.20)).rounded())
        upperKcal = Int((Double(base) * min(1, center + 0.20)).rounded()) + active
        lowerFraction = Double(lowerKcal) / Double(allowance)
        upperFraction = Double(upperKcal) / Double(allowance)
        usedFraction = min(1, Double(max(0, eatenKcal)) / Double(allowance))
        usedPercent = Int((100 * Double(max(0, eatenKcal)) / Double(allowance)).rounded())
    }

    private static func recentMealFraction(logs: [FoodLog], at minute: Int, now: Date) -> Double? {
        let calendar = Calendar.current
        guard let earliest = calendar.date(byAdding: .day, value: -28, to: now) else { return nil }
        let today = FoodDates.localDate(for: now)
        let firstDay = FoodDates.localDate(for: earliest)
        let recent = logs.filter { $0.localDate >= firstDay && $0.localDate < today }
        let days = Dictionary(grouping: recent, by: \.localDate)
        let fractions = days.values.compactMap { day -> Double? in
            guard day.count >= 2 else { return nil }
            let total = day.reduce(0) { $0 + $1.kcal }
            guard total >= 400 else { return nil }
            let byNow = day.reduce(0) { result, log in
                guard let date = FoodDates.parseTimestamp(log.loggedAt) else { return result }
                let components = calendar.dateComponents([.hour, .minute], from: date)
                let loggedMinute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                return result + (loggedMinute <= minute ? log.kcal : 0)
            }
            return Double(byNow) / Double(total)
        }.sorted()
        guard fractions.count >= 7 else { return nil }
        let middle = fractions.count / 2
        return fractions.count.isMultiple(of: 2)
            ? (fractions[middle - 1] + fractions[middle]) / 2
            : fractions[middle]
    }
}
