import SwiftUI

@main struct ZeroZeroFoodApp: App {
    @UIApplicationDelegateAdaptor(FoodAppDelegate.self) private var appDelegate
    @State private var store = FoodStore()
    @State private var health = HealthEnergy()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(health)
                .task {
                    if scenePhase == .active { DailyFeedbackBackground.schedule(for: store) }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        DailyFeedbackBackground.schedule(for: store)
                    }
                }
                .onChange(of: store.dailyFeedbackEnabled) { _, _ in
                    if scenePhase == .active || !store.dailyFeedbackEnabled {
                        DailyFeedbackBackground.schedule(for: store)
                    }
                }
                .onChange(of: store.accountId) { _, _ in
                    if scenePhase == .active || !store.signedIn {
                        DailyFeedbackBackground.schedule(for: store)
                    }
                }
        }
        .backgroundTask(.appRefresh(DailyFeedbackBackground.identifier)) {
            await DailyFeedbackBackground.refresh(store: store, health: health)
        }
    }
}
