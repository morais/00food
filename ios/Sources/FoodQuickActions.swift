import Observation
import SwiftUI
import UIKit

enum FoodQuickLaunch: String, Identifiable {
    case log
    case camera

    var id: String { rawValue }

    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "zerozerofood", parts.host == "log",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        switch parts.path {
        case "/food": self = .log
        case "/camera": self = .camera
        default: return nil
        }
    }
}

@MainActor @Observable final class FoodQuickActions {
    static let shared = FoodQuickActions()
    var pendingLaunch: FoodQuickLaunch?

    func handle(_ item: UIApplicationShortcutItem) -> Bool {
        switch item.type {
        case "com.00food.quick-add.log": pendingLaunch = .log
        case "com.00food.quick-add.camera": pendingLaunch = .camera
        default: return false
        }
        return true
    }
}

final class FoodAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in AgentResponsePush.shared.deviceToken = token }
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completion: @escaping (UIBackgroundFetchResult) -> Void) {
        guard userInfo["foodSync"] as? Bool == true else { completion(.noData); return }
        Task { @MainActor in completion(await AgentResponsePush.shared.receive()) }
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = FoodSceneDelegate.self
        return configuration
    }
}

final class FoodSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let item = connectionOptions.shortcutItem else { return }
        Task { @MainActor in _ = FoodQuickActions.shared.handle(item) }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            completionHandler(FoodQuickActions.shared.handle(shortcutItem))
        }
    }
}
