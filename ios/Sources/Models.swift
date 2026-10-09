import Foundation

struct HealthMeasurePoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

struct FoodProfile: Codable, Equatable {
    var heightCm: Double
    var weightKg: Double
    var estimateProfile: String
    var deficitKcal: Int
    var birthYear: Int?
    var updatedAt: String?

    var restingKcal: Int {
        // Mifflin-St Jeor uses age; a missing birth year retains the earlier
        // reference age so existing profiles keep a directional estimate.
        let age = birthYear.map { Calendar.current.component(.year, from: Date()) - $0 } ?? 35
        let offset: Double = switch estimateProfile {
        case "male": 5
        case "female": -161
        default: -78
        }
        return Int((10 * weightKg + 6.25 * heightCm - 5 * Double(age) + offset).rounded())
    }

    // Health active energy is added separately. Applying an activity
    // multiplier here would credit the same movement twice.
    var roughDailyTarget: Int { target(for: deficitKcal) }
    func target(for deficit: Int, resting: Int? = nil) -> Int {
        max(1200, (resting ?? restingKcal) - deficit)
    }
    func effectiveDeficit(for deficit: Int, resting: Int? = nil) -> Int {
        max(0, (resting ?? restingKcal) - target(for: deficit, resting: resting))
    }
}

enum DeficitLevel: Int, CaseIterable, Identifiable {
    case maintain = 0, gentle = 300, steady = 450, faster = 600
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .maintain: "Maintain"
        case .gentle: "Gentle"
        case .steady: "Steady"
        case .faster: "Faster"
        }
    }
    static func nearest(to value: Int) -> DeficitLevel {
        allCases.min { abs($0.rawValue - value) < abs($1.rawValue - value) } ?? .gentle
    }
}

struct ACEBodyFatBoundary: Identifiable, Equatable {
    let category: String
    let percentage: Double
    let isObesity: Bool
    var id: Int { Int(percentage) }
}

enum ProgressProjection {
    static func bodyFatAnchor(history: [HealthMeasurePoint], fallback: HealthMeasurePoint?) -> HealthMeasurePoint? {
        // Chart dots are daily averages. Anchor to the same value and date,
        // rather than mixing that dot with an individual reading or today.
        history.max { $0.date < $1.date } ?? fallback
    }

    static func bodyFatProjection(anchor: HealthMeasurePoint, startWeightKg: Double,
                                  gapKcal: Int, minimumWeightKg: Double, until end: Date,
                                  calendar: Calendar = .current) -> [HealthMeasurePoint] {
        guard anchor.date <= end, startWeightKg.isFinite, startWeightKg > 0,
              anchor.value.isFinite, (0...100).contains(anchor.value) else { return [] }
        let totalDays = max(0, calendar.dateComponents([.day], from: anchor.date, to: end).day ?? 0)
        var days = Array(stride(from: 0, through: totalDays, by: 7))
        if days.last != totalDays { days.append(totalDays) }
        return days.compactMap { day -> HealthMeasurePoint? in
            let weight = startWeightKg - Double(max(0, gapKcal)) * Double(day) / 7700
            guard weight >= minimumWeightKg,
                  let date = calendar.date(byAdding: .day, value: day, to: anchor.date) else { return nil }
            return day == 0 ? anchor : HealthMeasurePoint(date: date,
                value: bodyFatPercent(startWeightKg: startWeightKg, startBodyFatPercent: anchor.value,
                                      projectedWeightKg: weight))
        }
    }

    // ACE Personal Training Manual classification chart, reproduced by ACE:
    // https://www.acefitness.org/fitness-certifications/ace-answers/exam-preparation-blog/3815/anthropometric-measurements-when-to-use-this-assessment/
    static func aceBoundaries(for estimateProfile: String) -> [ACEBodyFatBoundary] {
        let values: [(String, Double)]
        switch estimateProfile {
        case "male": values = [("Obesity", 25), ("Average", 18), ("Fitness", 14),
                               ("Athletes", 6), ("Essential", 2)]
        case "female": values = [("Obesity", 32), ("Average", 25), ("Fitness", 21),
                                 ("Athletes", 14), ("Essential", 10)]
        default: return []
        }
        return values.enumerated().map { index, item in
            ACEBodyFatBoundary(category: item.0, percentage: item.1, isObesity: index == 0)
        }
    }

    static func visibleACEBoundaries(for estimateProfile: String,
                                     projectedPercentages: [Double]) -> [ACEBodyFatBoundary] {
        let values = projectedPercentages.filter(\.isFinite)
        guard let minimum = values.min(), let maximum = values.max() else {
            return aceBoundaries(for: estimateProfile).filter(\.isObesity)
        }
        return aceBoundaries(for: estimateProfile).filter { boundary in
            boundary.isObesity || (minimum < boundary.percentage && maximum >= boundary.percentage)
        }
    }

    static func bodyFatPercent(startWeightKg: Double, startBodyFatPercent: Double,
                               projectedWeightKg: Double) -> Double {
        guard startWeightKg > 0, projectedWeightKg > 0 else { return 0 }
        let startingFatKg = startWeightKg * startBodyFatPercent / 100
        let fatLostKg = max(0, startWeightKg - projectedWeightKg)
        return min(100, max(0, 100 * (startingFatKg - fatLostKg) / projectedWeightKg))
    }
}

struct FoodItem: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var serving: String
    var kcal: Int
    var source: String
    var useCount: Int
    var lastUsedAt: String?
    var dismissedAt: String?
    var createdAt: String
    var updatedAt: String
    var fruitVegPortions: Int? = nil
    var countedFruitVegPortions: Int { min(5, max(0, fruitVegPortions ?? 0)) }
}

struct FoodLog: Codable, Identifiable, Equatable {
    var id: String
    var foodId: String
    var foodName: String
    var serving: String
    var quantity: Double
    var kcal: Int
    var localDate: String
    var loggedAt: String
    var fruitVegPortions: Int? = nil
    var countedFruitVegPortions: Int { min(5, max(0, fruitVegPortions ?? 0)) }
}

struct PendingEstimation: Codable, Identifiable, Equatable {
    var id: String
    var description: String
    var hasPhoto: Bool
    var state: String
    var proposedName: String?
    var proposedServing: String?
    var proposedKcal: Int?
    var agentNote: String?
    var localDate: String
    var createdAt: String
    var updatedAt: String
    var reasoning: String? = nil
    var clarification: String? = nil
    var proposedFruitVegPortions: Int? = nil
}

struct FoodSnapshot: Codable {
    var accountId: String? = nil
    var startedAt: String?
    var profile: FoodProfile?
    var foods: [FoodItem]
    var logs: [FoodLog]
    var estimations: [PendingEstimation]
    var dailyFeedback: [DailyFeedbackRequest]? = nil
}

struct DailyHealthDay: Codable {
    var localDate: String
    var activeKcal: Int?
    var restingKcal: Int?
    var waterMl: Int?
    var weightKg: Double?
    var bodyFatPercent: Double?
}

struct DailyFeedbackRequest: Codable, Identifiable, Equatable {
    var id: String
    var localDate: String
    var state: String
    var feedback: String?
    var createdAt: String
    var updatedAt: String
}

struct DailyFeedbackUpload: Codable {
    var id: String
    var localDate: String
    var timeZone: String
    var healthDays: [DailyHealthDay]
}

enum FoodDates {
    static func today() -> String {
        localDate(for: Date())
    }

    static func localDate(for date: Date) -> String {
        let p = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }

    static func parseLocalDate(_ value: String) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func parseTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
