import Foundation

struct FoodProfile: Codable, Equatable {
    var heightCm: Double
    var weightKg: Double
    var estimateProfile: String
    var deficitKcal: Int
    var updatedAt: String?

    var roughDailyTarget: Int {
        // A deliberately simple directional estimate. The fixed reference
        // age keeps onboarding to the three inputs requested by the user.
        let offset: Double = switch estimateProfile {
        case "male": 5
        case "female": -161
        default: -78
        }
        let resting = 10 * weightKg + 6.25 * heightCm - 175 + offset
        return max(1200, Int((resting * 1.2).rounded()) - deficitKcal)
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
    var createdAt: String
    var updatedAt: String
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
}

struct FoodSnapshot: Decodable {
    var profile: FoodProfile?
    var foods: [FoodItem]
    var logs: [FoodLog]
    var estimations: [PendingEstimation]
}

struct SeedFood: Identifiable {
    var name: String
    var serving: String
    var kcal: Int
    var id: String { name }

    static let all: [SeedFood] = [
        .init(name: "Banana", serving: "1 medium", kcal: 105),
        .init(name: "Apple", serving: "1 medium", kcal: 95),
        .init(name: "Egg", serving: "1 large", kcal: 72),
        .init(name: "Toast", serving: "1 slice", kcal: 85),
        .init(name: "Oatmeal", serving: "1 bowl", kcal: 160),
        .init(name: "Greek yogurt", serving: "1 cup", kcal: 130),
        .init(name: "Coffee with milk", serving: "1 cup", kcal: 50),
        .init(name: "Cappuccino", serving: "1 cup", kcal: 120),
        .init(name: "Rice, cooked", serving: "1 cup", kcal: 205),
        .init(name: "Pasta, cooked", serving: "1 cup", kcal: 220),
        .init(name: "Chicken breast", serving: "100 g", kcal: 165),
        .init(name: "Salmon", serving: "100 g", kcal: 208),
        .init(name: "Mixed salad", serving: "1 bowl", kcal: 100),
        .init(name: "Olive oil", serving: "1 tablespoon", kcal: 120),
        .init(name: "Bread", serving: "1 slice", kcal: 90),
        .init(name: "Cheese", serving: "1 slice", kcal: 110),
        .init(name: "Pizza", serving: "1 slice", kcal: 285),
        .init(name: "Dark chocolate", serving: "1 square", kcal: 55),
        .init(name: "Beer", serving: "330 ml", kcal: 150),
        .init(name: "Wine", serving: "150 ml", kcal: 125),
    ]
}

enum FoodDates {
    static func today() -> String {
        let p = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }
}
