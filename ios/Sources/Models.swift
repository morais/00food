import Foundation

struct HealthMeasurePoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

enum HealthHistory {
    static func lastReadingEachDay(_ readings: [HealthMeasurePoint],
                                   calendar: Calendar = .current) -> [HealthMeasurePoint] {
        var days: [Date: HealthMeasurePoint] = [:]
        for reading in readings {
            let day = calendar.startOfDay(for: reading.date)
            if days[day] == nil || days[day]!.date < reading.date { days[day] = reading }
        }
        return days.values.sorted { $0.date < $1.date }
    }
}

struct FoodProfile: Codable, Equatable {
    var heightCm: Double
    var weightKg: Double
    var estimateProfile: String
    var deficitPercent: Int
    var updatedAt: String?

    var restingKcal: Int {
        // Keep the fallback directional without asking for date of birth.
        let age = 35
        let offset: Double = switch estimateProfile {
        case "male": 5
        case "female": -161
        default: -78
        }
        return Int((10 * weightKg + 6.25 * heightCm - 5 * Double(age) + offset).rounded())
    }

    func budget(resting: Int? = nil, active: Int = 0, deficitPercent: Int? = nil) -> CalorieBudget {
        CalorieBudget(tdeeKcal: (resting ?? restingKcal) + max(0, active),
                      deficitPercent: deficitPercent ?? self.deficitPercent)
    }
}

extension FoodProfile {
    private enum CodingKeys: String, CodingKey {
        case heightCm, weightKg, estimateProfile, deficitPercent, deficitKcal, updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        heightCm = try values.decode(Double.self, forKey: .heightCm)
        weightKg = try values.decode(Double.self, forKey: .weightKg)
        estimateProfile = try values.decode(String.self, forKey: .estimateProfile)
        if let percent = try values.decodeIfPresent(Int.self, forKey: .deficitPercent) {
            deficitPercent = percent
        } else {
            // Migrate cached profiles and pending offline profile saves in place.
            deficitPercent = DeficitLevel.fromLegacyKcal(try values.decode(Int.self, forKey: .deficitKcal)).rawValue
        }
        updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(heightCm, forKey: .heightCm)
        try values.encode(weightKg, forKey: .weightKg)
        try values.encode(estimateProfile, forKey: .estimateProfile)
        try values.encode(deficitPercent, forKey: .deficitPercent)
        try values.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }
}

// Apply the restriction to total expenditure, including exercise. Keep all
// surfaces on the same rounded budget; future calibration can supply TDEE here.
struct CalorieBudget: Equatable {
    let tdeeKcal: Int
    let deficitPercent: Int
    var allowanceKcal: Int {
        Int((Double(max(0, tdeeKcal)) * (1 - Double(deficitPercent) / 100)).rounded())
    }
    var gapKcal: Int { max(0, tdeeKcal) - allowanceKcal }
}

enum DeficitLevel: Int, CaseIterable, Identifiable {
    case maintain = 0, gentle = 10, balanced = 15, faster = 20
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .maintain: "Maintain"
        case .gentle: "Gentle"
        case .balanced: "Balanced"
        case .faster: "Faster"
        }
    }
    static func fromLegacyKcal(_ value: Int) -> DeficitLevel {
        if value == 0 { return .maintain }
        if value < 375 { return .gentle }
        if value < 525 { return .balanced }
        return .faster
    }
}

// Use paired, completed Health days to illustrate the selected percentage at
// representative expenditure. Today's partial exercise never anchors a forecast.
struct TDEESummary {
    let averageKcal: Int?
    let daysUsed: Int

    init(resting: [HealthMeasurePoint], active: [HealthMeasurePoint],
         now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let earliest = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        var activeByDay: [Date: Double] = [:]
        for point in active where point.value.isFinite && point.value >= 0 {
            activeByDay[calendar.startOfDay(for: point.date)] = point.value
        }
        let totals = resting.compactMap { point -> Double? in
            let day = calendar.startOfDay(for: point.date)
            guard day >= earliest, day < today, point.value.isFinite, point.value > 0,
                  let activity = activeByDay[day] else { return nil }
            return point.value + activity
        }
        daysUsed = totals.count
        averageKcal = totals.isEmpty ? nil : Int((totals.reduce(0, +) / Double(totals.count)).rounded())
    }
}

struct ACEBodyFatBoundary: Identifiable, Equatable {
    let category: String
    let percentage: Double
    let isObesity: Bool
    var id: Int { Int(percentage) }
}

enum ProgressProjection {
    static func healthyWeightRange(for heightCm: Double) -> ClosedRange<Double> {
        let heightSquared = pow(heightCm / 100, 2)
        return (18.5 * heightSquared)...(24.9 * heightSquared)
    }

    static func projectedWeight(from weight: Double, gap: Int, minimum: Double, until end: Date,
                                now: Date = Date(), calendar: Calendar = .current) -> [HealthMeasurePoint] {
        let today = calendar.startOfDay(for: now)
        let totalDays = max(0, calendar.dateComponents([.day], from: today, to: end).day ?? 0)
        var days = Array(stride(from: 0, through: totalDays, by: 7))
        if days.last != totalDays { days.append(totalDays) }
        return days.compactMap { day in
            guard let date = calendar.date(byAdding: .day, value: day, to: today) else { return nil }
            return HealthMeasurePoint(date: date, value: weight - Double(max(0, gap)) * Double(day) / 7700)
        }.prefix { $0.value >= minimum }.map { $0 }
    }

    static func estimatedBMIEntryDate(from weight: Double, gap: Int, upperBound: Double, until end: Date,
                                      now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard weight > upperBound, gap > 0 else { return nil }
        let today = calendar.startOfDay(for: now)
        let daysToEntry = Int(ceil((weight - upperBound) * 7700 / Double(gap)))
        guard let entry = calendar.date(byAdding: .day, value: daysToEntry, to: today),
              entry <= end else { return nil }
        return entry
    }

    static func bodyFatAnchor(history: [HealthMeasurePoint], fallback: HealthMeasurePoint?) -> HealthMeasurePoint? {
        // Keep the illustration attached to the last recorded chart dot.
        history.max { $0.date < $1.date } ?? fallback
    }

    static func bodyFatProjection(anchor: HealthMeasurePoint, startWeightKg: Double,
                                  gapKcal: Int, minimumWeightKg: Double, until end: Date,
                                  calendar: Calendar = .current) -> [HealthMeasurePoint] {
        guard anchor.date <= end, startWeightKg.isFinite, startWeightKg > 0,
              anchor.value.isFinite, (0...100).contains(anchor.value) else { return [] }
        let totalDays = max(0, calendar.dateComponents([.day], from: anchor.date, to: end).day ?? 0)
        var dates = stride(from: 0, through: totalDays, by: 7).compactMap {
            calendar.date(byAdding: .day, value: $0, to: anchor.date)
        }
        if dates.last != end { dates.append(end) }
        return dates.compactMap { date -> HealthMeasurePoint? in
            let elapsedDays = date.timeIntervalSince(anchor.date) / 86400
            let weight = startWeightKg - Double(max(0, gapKcal)) * elapsedDays / 7700
            guard weight >= minimumWeightKg else { return nil }
            return date == anchor.date ? anchor : HealthMeasurePoint(date: date,
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
