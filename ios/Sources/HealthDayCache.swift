import Foundation

// A display cache only: feedback requests still query Health directly. Keep one
// local day, and never treat yesterday's energy or water as today's readings.
struct HealthDaySnapshot: Codable {
    struct Day: Codable, Equatable {
        let start: Date
        let timeZone: String

        init(date: Date = Date(), calendar: Calendar = .current) {
            start = calendar.startOfDay(for: date)
            timeZone = calendar.timeZone.identifier
        }
    }

    struct Allowance: Codable {
        let activeKcal: Int
        let restingAverageKcal: Int?
        let restingDaysUsed: Int
        var completedAverageTDEEKcal: Int? = nil
        var completedTDEEDaysUsed: Int? = nil
    }

    let day: Day
    var allowance: Allowance?
    var waterMl: Int?
    var weightKg: Double?
    var weightDate: Date?
    var bodyFatPercent: Double?
    var bodyFatDate: Date?

    init(day: Day = Day()) { self.day = day }
}

struct HealthDayCache {
    private let defaults: UserDefaults
    private let key = "healthDaySnapshot.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load(on date: Date = Date(), calendar: Calendar = .current) -> HealthDaySnapshot? {
        guard let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(HealthDaySnapshot.self, from: data),
              snapshot.day == HealthDaySnapshot.Day(date: date, calendar: calendar) else { return nil }
        return snapshot
    }

    func save(_ snapshot: HealthDaySnapshot, on date: Date = Date(), calendar: Calendar = .current) {
        guard snapshot.day == HealthDaySnapshot.Day(date: date, calendar: calendar),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }
}
