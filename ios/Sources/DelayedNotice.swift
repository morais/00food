import SwiftUI

// Automatic refresh errors need to survive a short grace period before they
// become visible. A new refresh, successful retry, or leaving the screen
// cancels the pending notice, including its VoiceOver announcement.
struct DelayedNotice<Content: View>: View {
    let message: String?
    var isRefreshing = false
    @ViewBuilder var content: (String) -> Content
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmedState: NoticeState?

    private struct NoticeState: Equatable {
        let message: String?
        let refreshing: Bool
        let active: Bool
    }

    var body: some View {
        let state = NoticeState(message: message, refreshing: isRefreshing, active: scenePhase == .active)
        if let message, !isRefreshing, scenePhase == .active {
            // A layout container keeps the task alive even before its Text is
            // visible. An empty Group would never start that task.
            VStack(alignment: .leading, spacing: 0) {
                if confirmedState == state { content(message) }
            }
            .task(id: state) {
                confirmedState = nil
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                guard !Task.isCancelled else { return }
                confirmedState = state
            }
            .onDisappear { confirmedState = nil }
        }
    }
}
