import SwiftUI

@main struct ZeroZeroFoodApp: App {
    @UIApplicationDelegateAdaptor(FoodAppDelegate.self) private var appDelegate
    @State private var store: FoodStore
    @State private var health: HealthEnergy
    @State private var watchBridge: PhoneWatchBridge
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let foodStore = FoodStore()
        AgentResponsePush.shared.store = foodStore
        let healthData = HealthEnergy()
        _store = State(initialValue: foodStore)
        _health = State(initialValue: healthData)
        _watchBridge = State(initialValue: PhoneWatchBridge(store: foodStore, health: healthData))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(health)
                .onChange(of: watchBridge.content, initial: true) { _, _ in watchBridge.resume() }
                .task {
                    watchBridge.resume()
                    if scenePhase == .active { DailyFeedbackBackground.schedule(for: store) }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        watchBridge.resume()
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
