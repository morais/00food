import Foundation

// Fictional, local-only samples. This file is excluded from the shipping app.
enum ScreenshotFixtures {
    static let now: Date = {
        NSTimeZone.default = TimeZone(secondsFromGMT: 0)!
        return ISO8601DateFormatter().date(from: "2026-10-07T18:41:00Z")!
    }()
    static let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
    static var scenario: String {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--scene"), args.indices.contains(index + 1) else { return "overview" }
        return args[index + 1]
    }
    static func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    @MainActor static func configure(_ store: FoodStore) {
        store.accountId = "fictional-screenshot-account"
        store.accountEmail = "alex@example.invalid"
        store.startedAt = stamp(yesterday)
        store.profile = FoodProfile(heightCm: 178, weightKg: 76, estimateProfile: "neutral",
                                    deficitPercent: 0, updatedAt: stamp(now))
        let samples: [(String, String, Int, Int, Int)] = [
            ("Oats, yogurt & berries", "1 breakfast bowl", 320, 1, 12),
            ("Chicken, rice & vegetables", "1 lunch bowl", 540, 2, 9),
            ("Banana", "1 medium banana", 105, 1, 8),
            ("Tomato & lentil soup", "1 bowl · 350 mL", 320, 2, 6),
            ("Sourdough toast", "2 slices", 180, 0, 5),
            ("Yogurt & almonds", "1 small bowl", 250, 0, 3),
        ]
        store.foods = samples.enumerated().map { index, sample in
            FoodItem(id: "sample-food-\(index)", name: sample.0, serving: sample.1,
                     kcal: sample.2, source: "agent", useCount: sample.4,
                     lastUsedAt: stamp(now), dismissedAt: nil, createdAt: stamp(yesterday),
                     updatedAt: stamp(now), fruitVegPortions: sample.3)
        }
        func logs(_ date: Date, count: Int) -> [FoodLog] {
            store.foods.prefix(count).enumerated().map { index, food in
                let logged = Calendar.current.date(bySettingHour: [8, 12, 15, 18, 18, 20][index],
                                                    minute: index * 3, second: 0, of: date)!
                return FoodLog(id: "sample-\(FoodDates.localDate(for: date))-\(index)", foodId: food.id,
                               foodName: food.name, serving: food.serving, quantity: 1, kcal: food.kcal,
                               localDate: FoodDates.localDate(for: date), loggedAt: stamp(logged),
                               fruitVegPortions: food.fruitVegPortions)
            }
        }
        store.logs = logs(now, count: 5) + logs(yesterday, count: 6)
        precondition(store.logs(on: now).reduce(0) { $0 + $1.kcal } == 1465)
        precondition(store.logs(on: yesterday).reduce(0) { $0 + $1.kcal } == 1715)
        store.hasLoadedSnapshot = true
        store.hasLoadedConnections = true
        store.connections = [MCPConnection(id: "fictional-agent", clientName: "ChatGPT Work",
            scopes: ["food:read", "food:write", "daily:read", "daily:write"], connectedAt: stamp(yesterday), lastUsedAt: stamp(now),
            expiresAt: "2099-01-01T00:00:00Z", activeEvents: ["food.estimate_requested", "food.clarification_added",
                                                             "food.logged", "day.feedback_requested"])]
        if scenario == "estimate" || scenario == "clarification" {
            let revised = scenario == "clarification"
            store.estimations = [PendingEstimation(id: "sample-yogurt-estimate",
                description: "Small bowl: yogurt, berries & almonds", hasPhoto: false,
                state: "proposed", proposedName: revised ? "Yogurt, berries & honey" : "Yogurt, berries & almonds",
                proposedServing: "1 small bowl", proposedKcal: revised ? 230 : 190,
                agentNote: revised ? "Updated with the honey you mentioned. Review before logging." :
                    "An approximate estimate. Add details if the portion or ingredients differ.",
                localDate: FoodDates.localDate(for: now), createdAt: stamp(now), updatedAt: stamp(now),
                reasoning: revised ? "Original bowl ~190 kcal, plus ~40 kcal for two teaspoons of honey. Total: about 230 kcal." :
                    "Plain yogurt ~100 kcal, berries ~50 and almonds ~40. Total: about 190 kcal; portion sizes are assumed.",
                clarification: revised ? "I also added two teaspoons of honey." : nil,
                proposedFruitVegPortions: 1)]
        }
        if scenario == "review" {
            store.dailyFeedbackEnabled = true
            store.dailyFeedback = [DailyFeedbackRequest(id: "sample-daily-review",
                localDate: FoodDates.localDate(for: yesterday), state: "ready",
                feedback: "Your log adds up to 1,715 kcal, with at least five fruit and veg portions. Apple Health recorded 420 active kcal and 1,750 mL of water.\n\nYou reused your breakfast and lunch favourites, then added soup and toast for dinner. That gives you a useful record without estimating the same meals again.\n\nThese calorie totals are approximate. If an ingredient or portion was different, you can clarify it before saving the next estimate.",
                createdAt: stamp(now), updatedAt: stamp(now))]
        }
    }
    @MainActor static func configure(_ health: HealthEnergy) {
        health.activeKcal = 420
        health.waterMlToday = 1500
        health.restingAverageKcal = 1850
        health.restingDaysUsed = 7
        health.latestWeightKg = 76
        health.latestWeightDate = now
        health.requested = true
        health.restingRequested = true
        health.waterRequested = true
        health.weightRequested = true
    }
}
