import SwiftUI

@main struct ZeroZeroFoodApp: App {
    @State private var store = FoodStore()
    @State private var health = HealthEnergy()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(health)
        }
    }
}
