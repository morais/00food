import Foundation
import WidgetKit

// Only the values rendered by the widget are shared. Tokens and food history stay in the app.
struct FoodWidgetSnapshot: Codable, Equatable {
    var localDate: String
    var targetKcal: Int
    var consumedKcal: Int
    var activeKcal: Int
    var pendingCount: Int
    var startMinutes: Int
    var endMinutes: Int

    var allowanceKcal: Int { targetKcal + activeKcal }
    var remainingKcal: Int { allowanceKcal - consumedKcal }

    func isCurrent(at date: Date) -> Bool { localDate == Self.localDate(for: date) }

    static func localDate(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

enum FoodWidgetSnapshotStore {
    static let kind = "FoodBalanceWidget"
    static let groupID = Bundle.main.object(forInfoDictionaryKey: "FoodAppGroup") as? String
    static let pendingLaunchKey = "pendingLogLaunch"
    static let sharedDefaults = groupID.flatMap { UserDefaults(suiteName: $0) }
    private static let snapshotKey = "foodWidgetSnapshot"

    static func load() -> FoodWidgetSnapshot? {
        guard let data = sharedDefaults?.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(FoodWidgetSnapshot.self, from: data)
    }

    static func save(_ snapshot: FoodWidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot),
              sharedDefaults?.data(forKey: snapshotKey) != data else { return }
        sharedDefaults?.set(data, forKey: snapshotKey)
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }

    static func clear() {
        guard sharedDefaults?.object(forKey: snapshotKey) != nil else { return }
        sharedDefaults?.removeObject(forKey: snapshotKey)
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }
}
