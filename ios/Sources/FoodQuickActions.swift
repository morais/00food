import Observation
import SwiftUI
import UIKit

enum FoodQuickLaunch: String, Identifiable {
    case log
    case camera

    var id: String { rawValue }
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
