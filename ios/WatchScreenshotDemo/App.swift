import SwiftUI

@main struct WatchScreenshotDemoApp: App {
    @State private var store = WatchStore()
    var body: some Scene {
        WindowGroup {
            WatchHomeView().environment(store)
        }
    }
}
