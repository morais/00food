import Foundation
import HealthKit
import WatchConnectivity

@MainActor final class PhoneWatchBridge: NSObject, WCSessionDelegate {
    private let store: FoodStore
    private let health: HealthEnergy
    private let session = WCSession.default
    private var inbox = WatchInboxState()
    private var processing = false
    private var needsDiskReload = false
    private var refreshing = false
    private var lastRefreshAt: Date?
    private var lastPublished: WatchSnapshot?

    init(store: FoodStore, health: HealthEnergy) {
        self.store = store
        self.health = health
        super.init()
        do { inbox = try WatchDisk.load(WatchInboxState.self, name: "phone-inbox") ?? WatchInboxState() }
        catch { needsDiskReload = true }
        if WCSession.isSupported() {
            session.delegate = self
            session.activate()
        }
    }

    // This comparison value has a fixed timestamp; SwiftUI publishes only when
    // its content changes, rather than entering a date-driven update loop.
    var content: WatchSnapshot {
        var value = WatchSnapshot()
        value.accountId = store.signedIn ? store.accountId : nil
        value.ready = store.signedIn && store.hasLoadedSnapshot && store.profile != nil && store.accountId != nil
        if value.ready, let profile = store.profile {
            value.budgetKcal = health.dailyBudget(for: profile).allowanceKcal
            // Keep older Watch copies correct while their update is installing.
            value.targetKcal = (value.budgetKcal ?? 0) - health.activeKcal
            value.activeKcal = health.activeKcal
            value.consumedKcal = store.consumedToday
            value.waterMl = health.waterMlToday
            value.fruitVegPortions = store.todaysLogs.reduce(0) { $0 + $1.countedFruitVegPortions }
            value.allowanceReady = health.allowanceIsReady
            value.foods = Array(store.foods.filter { $0.dismissedAt == nil }.sorted {
                if $0.useCount != $1.useCount { return $0.useCount > $1.useCount }
                if $0.lastUsedAt != $1.lastUsedAt { return ($0.lastUsedAt ?? "") > ($1.lastUsedAt ?? "") }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }.prefix(50))
            value.loggedIds = store.todaysLogs.map(\.id)
            value.estimates = store.estimations.map {
                WatchEstimate(id: $0.id, name: $0.proposedName ?? ($0.description.isEmpty ? "Food photo" : $0.description), state: $0.state)
            }
        }
        value.receipts = Array(inbox.receipts.suffix(200))
        let defaults = UserDefaults.standard
        value.measurementSystem = MeasurementPreference.current(defaults: defaults).rawValue
        value.startMinutes = defaults.object(forKey: "activeDayStartMinutes") as? Int ?? 7 * 60
        value.endMinutes = defaults.object(forKey: "activeDayEndMinutes") as? Int ?? 23 * 60
        return value
    }

    func publish() {
        guard restoreIfNeeded(), !processing, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        var value = content
        value.updatedAt = Date()
        guard let data = try? JSONEncoder().encode(value) else { return }
        lastPublished = value
        try? session.updateApplicationContext(["snapshot": data])
        if session.isReachable { session.sendMessage(["snapshot": data], replyHandler: nil, errorHandler: { _ in }) }
    }

    func resume() {
        health.resetReadingsForNewDay()
        publish()
        Task { await processPending() }
    }

    private func receive(_ command: WatchCommand) {
        guard restoreIfNeeded() else { return }
        if let index = inbox.receipts.firstIndex(where: { $0.id == command.id }) {
            // Keep a retried action's receipt in the next snapshot too.
            let receipt = inbox.receipts.remove(at: index)
            inbox.receipts.append(receipt)
            try? persist()
            publish()
            return
        }
        let previous = inbox
        inbox.enqueue(command)
        do { try persist() }
        catch { inbox = previous; return } // No acknowledgement until durably saved.
        Task { await processPending() }
    }

    private func persist() throws { try WatchDisk.save(inbox, name: "phone-inbox") }

    private func refreshFromWatch() async {
        guard store.signedIn, !refreshing,
              lastRefreshAt.map({ Date().timeIntervalSince($0) >= 15 }) ?? true else { return }
        refreshing = true
        defer { refreshing = false }
        lastRefreshAt = Date()
        try? await store.refresh()
        health.setHistoryStart(store.accountStartedAt)
        await health.refresh()
        if let accountId = store.accountId {
            health.configureDietaryExport(accountId: accountId)
            await health.syncDietaryEnergy(logs: store.logs, accountId: accountId)
        }
        resume()
    }

    private func restoreIfNeeded() -> Bool {
        guard needsDiskReload else { return true }
        do {
            inbox = try WatchDisk.load(WatchInboxState.self, name: "phone-inbox") ?? WatchInboxState()
            needsDiskReload = false
            return true
        } catch { return false }
    }

    private func processPending() async {
        guard restoreIfNeeded(), !processing else { return }
        processing = true
        defer { processing = false; publish() }
        while let command = inbox.pending.first {
            // A launch may still be loading the account. Keep its commands for
            // the next account refresh instead of rejecting them prematurely.
            if store.signedIn && (!store.hasLoadedSnapshot || store.accountId == nil) { return }
            var errorMessage: String?
            do {
                try command.validate()
                guard store.signedIn, command.accountId == store.accountId else {
                    throw WatchActionError(message: "Sign in to the same 00Food account on your iPhone before logging from the Watch.")
                }
                try await apply(command)
            } catch {
                if HealthQueryResult.isTemporarilyUnavailable(error) { return }
                errorMessage = error.localizedDescription
            }
            let previous = inbox
            inbox.pending.removeFirst()
            inbox.completed.append(command)
            inbox.receipts.append(WatchReceipt(id: command.id, accepted: errorMessage == nil, error: errorMessage, date: Date()))
            let oldest = Date().addingTimeInterval(-90 * 86400)
            inbox.completed.removeAll { $0.createdAt < oldest }
            inbox.receipts.removeAll { $0.date < oldest }
            do { try persist() }
            catch { inbox = previous; return }
        }
    }

    private func apply(_ command: WatchCommand) async throws {
        if inbox.cancelledIds.contains(command.id) { return }
        switch command.kind {
        case .food:
            guard let food = store.foods.first(where: { $0.id == command.food?.id }) else {
                throw WatchActionError(message: "This food is no longer in your library. Refresh your Watch from the iPhone.")
            }
            try await store.log(food, quantity: command.quantity, id: command.id,
                                loggedAt: command.createdAt, localDate: command.localDate)
        case .estimate:
            try await store.requestEstimate(description: command.description ?? "", photo: nil,
                                            id: command.id, localDate: command.localDate)
        case .water:
            try await health.applyWatchWater(id: command.id, accountId: command.accountId, at: command.createdAt)
        case .undo:
            if let target = command.undoTarget, !inbox.cancelledIds.contains(target) {
                inbox.cancelledIds.append(target)
            }
            guard let original = inbox.completed.first(where: { $0.id == command.undoTarget && $0.accountId == command.accountId }),
                  inbox.receipts.contains(where: { $0.id == original.id && $0.accepted }) else { return }
            switch original.kind {
            case .food:
                if let log = store.logs.first(where: { $0.id == original.id }) { try await store.deleteLog(log) }
            case .estimate:
                if let estimate = store.estimations.first(where: { $0.id == original.id }) { try await store.deleteEstimation(estimate) }
            case .water:
                try await health.applyWatchWater(id: original.id, accountId: original.accountId,
                                                 at: original.createdAt, undo: true)
            case .undo: break
            }
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.resume() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) { Task { @MainActor in self.resume() } }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        decodeCommand(userInfo)
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { decodeCommand(message) }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        decodeCommand(message)
        Task { @MainActor in
            // A quick cached reply keeps Watch UI responsive. Avoid exposing a
            // half-applied water action while its receipt is still pending.
            var value = self.processing ? self.lastPublished : self.content
            if !self.processing { value?.updatedAt = Date() }
            replyHandler(value.flatMap { try? JSONEncoder().encode($0) }.map { ["snapshot": $0] } ?? [:])
            if message["refresh"] as? Bool == true { await self.refreshFromWatch() }
        }
    }
    private nonisolated func decodeCommand(_ payload: [String: Any]) {
        guard let data = payload["command"] as? Data,
              let command = try? JSONDecoder().decode(WatchCommand.self, from: data) else { return }
        Task { @MainActor in self.receive(command) }
    }
}
