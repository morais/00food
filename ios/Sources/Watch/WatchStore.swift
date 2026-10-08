import Foundation
import Observation
import WatchConnectivity
import WatchKit
import WidgetKit

@MainActor @Observable final class WatchStore: NSObject, WCSessionDelegate {
    private(set) var state = WatchTransferState()
    var errorMessage: String?
    var confirmation: WatchCommand?
    private let session = WCSession.default
    private var needsDiskReload = false

    override init() {
        super.init()
        do { state = try WatchDisk.load(WatchTransferState.self, name: "watch-state") ?? WatchTransferState() }
        catch { needsDiskReload = true }
        if WCSession.isSupported() {
            session.delegate = self
            session.activate()
        }
    }

    var pendingCount: Int { state.commands.count }

    func refresh() {
        guard restoreIfNeeded(), session.activationState == .activated else { return }
        receive(session.receivedApplicationContext)
        sendQueuedCommands()
        if session.isReachable {
            session.sendMessage(["refresh": true], replyHandler: { reply in
                Task { @MainActor in self.receive(reply) }
            }, errorHandler: { _ in })
        }
    }

    func log(_ food: FoodItem, quantity: Double = 1) {
        enqueue(kind: .food) { $0.food = food; $0.quantity = quantity }
    }
    func addWater() { enqueue(kind: .water) { _ in } }
    func estimate(_ description: String) {
        enqueue(kind: .estimate) { $0.description = description.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    func undo() {
        guard let original = confirmation else { return }
        enqueue(kind: .undo) {
            $0.undoTarget = original.id
            $0.undoKind = original.kind
            $0.undoLocalDate = original.localDate
            $0.food = original.food
            $0.quantity = original.quantity
        }
    }

    private func enqueue(kind: WatchCommand.Kind, fill: (inout WatchCommand) -> Void) {
        guard restoreIfNeeded() else { errorMessage = "Unlock your Watch to access your saved food logs."; return }
        guard let snapshot = state.snapshot, snapshot.ready, let accountId = snapshot.accountId else {
            errorMessage = "Open 00Food on your iPhone to finish setting up your account."
            return
        }
        var command = WatchCommand(accountId: accountId, kind: kind)
        fill(&command)
        let previous = state
        do {
            try command.validate()
            if let target = command.undoTarget { state.cancelledIds.append(target) }
            state.commands.append(command)
            try persist()
            confirmation = command
            WKInterfaceDevice.current().play(.success)
            send(command)
        } catch { state = previous; errorMessage = error.localizedDescription }
    }

    private func persist() throws {
        try WatchDisk.save(state, name: "watch-state")
        WidgetCenter.shared.reloadTimelines(ofKind: "FoodWatchBalance")
    }

    private func restoreIfNeeded() -> Bool {
        guard needsDiskReload else { return true }
        do {
            state = try WatchDisk.load(WatchTransferState.self, name: "watch-state") ?? WatchTransferState()
            needsDiskReload = false
            return true
        } catch { return false }
    }

    private func sendQueuedCommands() {
        for command in state.commands { send(command) }
    }

    private func send(_ command: WatchCommand) {
        guard session.activationState == .activated,
              let data = try? JSONEncoder().encode(command) else { return }
        let alreadyQueued = session.outstandingUserInfoTransfers.contains {
            ($0.userInfo["commandId"] as? String) == command.id
        }
        if !alreadyQueued { session.transferUserInfo(["commandId": command.id, "command": data]) }
        if session.isReachable {
            session.sendMessage(["command": data], replyHandler: nil, errorHandler: { _ in })
        }
    }

    private func receive(_ payload: [String: Any]) {
        guard restoreIfNeeded() else { return }
        guard let data = payload["snapshot"] as? Data,
              let snapshot = try? JSONDecoder().decode(WatchSnapshot.self, from: data) else { return }
        let previous = state
        let receipts = state.receive(snapshot)
        do { try persist() }
        catch { state = previous; return }
        if let rejected = receipts.first(where: { !$0.accepted }) {
            errorMessage = rejected.error ?? "This action could not be saved on your iPhone."
            if confirmation?.id == rejected.id { confirmation = nil }
            WKInterfaceDevice.current().play(.failure)
        }
        let completedIds = Set(receipts.map(\.id))
        for transfer in session.outstandingUserInfoTransfers {
            if let id = transfer.userInfo["commandId"] as? String, completedIds.contains(id) { transfer.cancel() }
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.refresh() }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) { Task { @MainActor in self.refresh() } }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.receive(applicationContext) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.receive(message) }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in self.receive(userInfo) }
    }
}
