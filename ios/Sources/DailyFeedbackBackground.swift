import BackgroundTasks
import Foundation
import OSLog
import UIKit

enum DailyFeedbackSchedule {
    static func nextRefresh(after now: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 15),
                          matchingPolicy: .nextTime) ?? now.addingTimeInterval(24 * 60 * 60)
    }
}

@MainActor enum DailyFeedbackBackground {
    static let identifier = (Bundle.main.bundleIdentifier ?? "com.00food.app") + ".daily-feedback"
    private static let logger = Logger(subsystem: "00food", category: "daily-feedback-background")
    private static let submissionQueue = DispatchQueue(label: "00food.daily-feedback-scheduling")

    static func schedule(for store: FoodStore, retry: Bool = false) {
        let taskIdentifier = identifier
        let enabled = store.signedIn && store.dailyFeedbackEnabled
        let logger = logger
        let earliestBeginDate = retry
            ? Date().addingTimeInterval(60 * 60)
            : DailyFeedbackSchedule.nextRefresh(after: Date())
        // iOS 27's submission API reports errors asynchronously and must be
        // called off the main thread. Keep submissions and cancellation ordered.
        submissionQueue.async {
            guard enabled else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
                return
            }
            let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
            request.earliestBeginDate = earliestBeginDate
            BGTaskScheduler.shared.submitTaskRequest(request) { error in
                if let error {
                    logger.info("Could not schedule daily feedback refresh: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    static func refresh(store: FoodStore, health: HealthEnergy) async {
        guard store.signedIn, store.dailyFeedbackEnabled else { return }
        // Submit the next request before doing work, in case iOS expires this run.
        schedule(for: store, retry: true)
        let accountToken = store.token
        do {
            guard UIApplication.shared.isProtectedDataAvailable else {
                logger.info("Daily feedback refresh deferred until protected data is available")
                return
            }
            try await store.refreshAndWait()
            guard store.token == accountToken, store.dailyFeedbackEnabled else { return }
            let count = try await store.requestMissingDailyFeedback(using: health, includeHistory: false,
                                                                   requireAccessibleHealth: true)
            try await store.refreshAndWait()
            logger.info("Daily feedback refresh completed; queued \(count) review requests")
            schedule(for: store)
        } catch {
            // Requests saved before interruption remain in the normal offline queue.
            logger.info("Daily feedback refresh deferred; it will retry later")
            schedule(for: store, retry: true)
        }
    }
}
