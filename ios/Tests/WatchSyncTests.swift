import XCTest
@testable import ZeroZeroFood

final class WatchSyncTests: XCTestCase {
    private let account = "watch-test-account"
    private var food: FoodItem {
        FoodItem(id: UUID().uuidString.lowercased(), name: "Yogurt", serving: "1 bowl", kcal: 200,
                 source: "manual", useCount: 4, createdAt: "2026-10-08T07:00:00Z",
                 updatedAt: "2026-10-08T07:00:00Z", fruitVegPortions: 1)
    }
    private func snapshot() -> WatchSnapshot {
        var value = WatchSnapshot()
        value.accountId = account
        value.ready = true
        value.allowanceReady = true
        value.targetKcal = 1500
        value.activeKcal = 500
        value.consumedKcal = 800
        value.waterMl = 750
        value.fruitVegPortions = 2
        value.updatedAt = Date()
        return value
    }

    func testPendingFoodAndWaterSurviveRestartAndKeepTheOriginalDay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var log = WatchCommand(accountId: account, kind: .food)
        log.food = food
        log.quantity = 1.5
        let water = WatchCommand(accountId: account, kind: .water)
        let state = WatchTransferState(snapshot: snapshot(), commands: [log, water])
        try WatchDisk.save(state, name: "watch-state", in: directory)
        let restored = try XCTUnwrap(WatchDisk.load(WatchTransferState.self, name: "watch-state", in: directory))
        XCTAssertEqual(restored.commands.map(\.id), [log.id, water.id])
        XCTAssertEqual(restored.commands.first?.createdAt, log.createdAt)
        XCTAssertEqual(restored.commands.first?.localDate, log.localDate)
        let balance = try XCTUnwrap(restored.balance())
        XCTAssertEqual(balance.consumedKcal, 1100)
        XCTAssertEqual(balance.waterMl, 1000)
        XCTAssertEqual(balance.fruitVegPortions, 4)
    }

    func testFoodIsNotCountedTwiceBeforeItsReceiptArrives() throws {
        var log = WatchCommand(accountId: account, kind: .food)
        log.food = food
        var value = snapshot()
        value.consumedKcal = 1000
        value.loggedIds = [log.id]
        var state = WatchTransferState(snapshot: value, commands: [log])
        XCTAssertEqual(state.balance()?.consumedKcal, 1000)
        value.receipts = [WatchReceipt(id: log.id, accepted: true, error: nil, date: Date())]
        value.updatedAt = Date().addingTimeInterval(1)
        XCTAssertEqual(state.receive(value).count, 1)
        XCTAssertTrue(state.commands.isEmpty)
        XCTAssertEqual(state.balance()?.consumedKcal, 1000)
    }

    func testUndoCancelsAnOfflineActionAndItsLateReceipt() {
        let water = WatchCommand(accountId: account, kind: .water)
        var undo = WatchCommand(accountId: account, kind: .undo)
        undo.undoTarget = water.id
        undo.undoKind = .water
        undo.undoLocalDate = water.localDate
        var state = WatchTransferState(snapshot: snapshot(), commands: [water, undo], cancelledIds: [water.id])
        XCTAssertEqual(state.balance()?.waterMl, 750)
        var update = snapshot()
        update.updatedAt = Date().addingTimeInterval(1)
        update.receipts = [WatchReceipt(id: undo.id, accepted: true, error: nil, date: Date())]
        XCTAssertEqual(state.receive(update).count, 1)
        XCTAssertEqual(state.commands.map(\.id), [water.id])
        XCTAssertEqual(state.balance()?.waterMl, 750, "A late original command stays cancelled after Undo is acknowledged")
    }

    func testUndoAfterAcknowledgementRemovesFoodAndWaterOptimistically() {
        var log = WatchCommand(accountId: account, kind: .food)
        log.food = food
        var undo = WatchCommand(accountId: account, kind: .undo)
        undo.undoTarget = log.id
        undo.undoKind = .food
        undo.undoLocalDate = log.localDate
        undo.food = log.food
        var value = snapshot()
        value.loggedIds = [log.id]
        var state = WatchTransferState(snapshot: value, commands: [undo])
        XCTAssertEqual(state.balance()?.consumedKcal, 600)
        XCTAssertEqual(state.balance()?.fruitVegPortions, 1)

        let water = WatchCommand(accountId: account, kind: .water)
        undo.undoTarget = water.id
        undo.undoKind = .water
        value.receipts = [WatchReceipt(id: water.id, accepted: true, error: nil, date: Date())]
        state = WatchTransferState(snapshot: value, commands: [undo])
        XCTAssertEqual(state.balance()?.waterMl, 500)
    }

    func testOldSnapshotsAndOtherAccountsDoNotOverwriteCurrentBalance() {
        var old = snapshot()
        old.updatedAt = old.updatedAt.addingTimeInterval(-60)
        old.consumedKcal = 0
        var foreign = WatchCommand(accountId: "another-account", kind: .food)
        foreign.food = food
        var state = WatchTransferState(snapshot: snapshot(), commands: [foreign])
        XCTAssertTrue(state.receive(old).isEmpty)
        XCTAssertEqual(state.balance()?.consumedKcal, 800)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        XCTAssertNil(state.balance(at: tomorrow))
    }

    func testInboxDeduplicatesDeliveryAcrossImmediateAndBackgroundChannels() {
        let command = WatchCommand(accountId: account, kind: .water)
        var inbox = WatchInboxState()
        inbox.enqueue(command)
        inbox.enqueue(command)
        XCTAssertEqual(inbox.pending.count, 1)
        inbox.pending = []
        inbox.receipts = [WatchReceipt(id: command.id, accepted: true, error: nil, date: Date())]
        inbox.enqueue(command)
        XCTAssertTrue(inbox.pending.isEmpty)
    }

    func testMalformedAndExpiredCommandsAreRejected() {
        var command = WatchCommand(accountId: account, kind: .food)
        command.food = food
        command.quantity = .nan
        XCTAssertThrowsError(try command.validate())
        let expired = WatchCommand(accountId: account, kind: .water, at: Date().addingTimeInterval(-91 * 86400))
        XCTAssertThrowsError(try expired.validate())
    }
}
