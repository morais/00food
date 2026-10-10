import Foundation

enum WatchScreenshotFixtures {
    static let now = ISO8601DateFormatter().date(from: "2026-10-07T18:41:00Z")!
    static var scenario: String {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--scene"), args.indices.contains(i + 1) else { return "overview" }
        return args[i + 1]
    }
    static var route: String? {
        switch scenario {
        case "library", "portion": "food"
        case "water": "water"
        case "describe": "describe"
        case "estimates": "estimates"
        default: nil
        }
    }
    static let foods: [FoodItem] = [
        food("00000000-0000-4000-8000-000000000001", "Banana oats", "one bowl", 350, 1),
        food("00000000-0000-4000-8000-000000000002", "Vegetable soup", "one bowl", 180, 2),
        food("00000000-0000-4000-8000-000000000003", "Chicken salad", "one plate", 420, 2),
    ]
    private static func food(_ id: String, _ name: String, _ serving: String, _ kcal: Int, _ portions: Int) -> FoodItem {
        FoodItem(id: id, name: name, serving: serving, kcal: kcal, source: "agent", useCount: 4,
                 createdAt: "2026-10-07T09:00:00Z", updatedAt: "2026-10-07T09:00:00Z", fruitVegPortions: portions)
    }
    static func state() -> WatchTransferState {
        var snapshot = WatchSnapshot()
        snapshot.accountId = "fictional-screenshot-account"
        snapshot.ready = true
        snapshot.localDate = FoodDates.localDate(for: now)
        snapshot.timeZone = TimeZone.current.identifier
        snapshot.updatedAt = now
        snapshot.budgetKcal = 2150
        snapshot.measurementSystem = "metric"
        snapshot.targetKcal = 1600
        snapshot.activeKcal = 550
        snapshot.consumedKcal = 1235
        snapshot.waterMl = 1500
        snapshot.fruitVegPortions = 4
        snapshot.allowanceReady = true
        snapshot.foods = foods
        snapshot.estimates = scenario == "overview" ? [] : [
            WatchEstimate(id: "00000000-0000-4000-8000-000000000004", name: "Yogurt & berries", state: "proposed"),
            WatchEstimate(id: "00000000-0000-4000-8000-000000000005", name: "Lunch bowl", state: "pending"),
        ]
        return WatchTransferState(snapshot: snapshot)
    }
}
