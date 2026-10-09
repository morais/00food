import Foundation
import Observation
import UIKit

@MainActor @Observable final class AgentResponsePush {
    static let shared = AgentResponsePush()
    var deviceToken: String?
    @ObservationIgnored weak var store: FoodStore?
    @ObservationIgnored private var lastRegistration: (account: String, device: String, date: Date)?

    struct Scope: Equatable {
        let account: String
        let device: String?
        let active: Bool
        let online: Bool
    }

    func registerDevice(using store: FoodStore) async {
        guard store.signedIn else {
            UIApplication.shared.unregisterForRemoteNotifications()
            lastRegistration = nil
            return
        }
        // Silent updates do not request permission for banners, sounds or badges.
        UIApplication.shared.registerForRemoteNotifications()
        guard let device = deviceToken else { return }
        let account = store.token
        if let previous = lastRegistration, previous.account == account, previous.device == device,
           Date().timeIntervalSince(previous.date) < 12 * 60 * 60 { return }
        let defaults = UserDefaults.standard
        let installation = defaults.string(forKey: "pushInstallationId") ?? UUID().uuidString.lowercased()
        defaults.set(installation, forKey: "pushInstallationId")
        let environment = Bundle.main.object(forInfoDictionaryKey: "FoodPushEnvironment") as? String ?? "development"
        while !Task.isCancelled && store.token == account {
            do {
                try await store.registerPushDevice(installationId: installation, deviceToken: device, environment: environment)
                guard store.token == account, !Task.isCancelled else { return }
                lastRegistration = (account, device, Date())
                return
            } catch {
                guard !Task.isCancelled else { return }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    func receive() async -> UIBackgroundFetchResult {
        guard let store, store.signedIn else { return .noData }
        return await withTaskGroup(of: UIBackgroundFetchResult.self) { group in
            group.addTask { @MainActor in await self.refreshAfterPush(using: store) }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return .failed
            }
            let result = await group.next() ?? .failed
            group.cancelAll()
            return result
        }
    }

    private func refreshAfterPush(using store: FoodStore) async -> UIBackgroundFetchResult {
        let account = store.token
        let before = responseVersions(in: store)
        do {
            try await store.refreshAndWait(quiet: true)
            guard store.token == account else { return .noData }
            return before == responseVersions(in: store) ? .noData : .newData
        } catch { return .failed }
    }

    private func responseVersions(in store: FoodStore) -> [String] {
        (store.estimations.map { "food:\($0.id):\($0.updatedAt)" } +
         store.dailyFeedback.map { "day:\($0.id):\($0.updatedAt)" }).sorted()
    }
}
