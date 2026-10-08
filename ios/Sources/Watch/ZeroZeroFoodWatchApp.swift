import SwiftUI
import WatchKit
import WatchConnectivity

@main struct ZeroZeroFoodWatchApp: App {
    @WKApplicationDelegateAdaptor(FoodWatchDelegate.self) private var delegate
    @State private var store = WatchStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .environment(store)
                .task { store.refresh() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { store.refresh() }
                }
        }
    }
}

@MainActor final class FoodWatchDelegate: NSObject, WKApplicationDelegate {
    private var pending: [WKWatchConnectivityRefreshBackgroundTask] = []
    private var observations: [NSKeyValueObservation] = []

    override init() {
        super.init()
        observations = [
            WCSession.default.observe(\.activationState, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.completeConnectivityTasks() }
            },
            WCSession.default.observe(\.hasContentPending, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.completeConnectivityTasks() }
            },
        ]
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let connectivity = task as? WKWatchConnectivityRefreshBackgroundTask { pending.append(connectivity) }
            else { task.setTaskCompletedWithSnapshot(false) }
        }
        completeConnectivityTasks()
    }

    private func completeConnectivityTasks() {
        Task { @MainActor in
            // Incoming delegate callbacks save their snapshots on this actor.
            await Task.yield()
            guard WCSession.default.activationState == .activated, !WCSession.default.hasContentPending else { return }
            for task in pending { task.setTaskCompletedWithSnapshot(false) }
            pending.removeAll()
        }
    }
}
