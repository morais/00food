import SwiftUI

@main struct ScreenshotDemoApp: App {
    @State private var store = FoodStore()
    @State private var health: HealthEnergy = {
        let health = HealthEnergy()
        ScreenshotFixtures.configure(health)
        return health
    }()
    var body: some Scene {
        WindowGroup {
            Group {
                switch ScreenshotFixtures.scenario {
                case "library", "new-food": QuickAddView()
                case "estimate", "clarification": ReviewEstimationView(estimation: store.estimations[0])
                default: HomeView()
                }
            }
            .environment(store)
            .environment(health)
        }
    }
}
