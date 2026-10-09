import XCTest
@testable import ZeroZeroFood

final class AgentResponsePollingTests: XCTestCase {
    @MainActor func testChecksFastInitiallyThenBacksOffWithoutRefreshingHealth() async {
        var current = Date(timeIntervalSince1970: 0)
        var intervals: [TimeInterval] = []
        var checks = 0
        await AgentResponsePolling.run(check: { checks += 1 }, now: { current }, wait: { interval in
            if intervals.count == 10 { throw CancellationError() }
            intervals.append(interval)
            current = current.addingTimeInterval(interval)
        })
        XCTAssertEqual(intervals, Array(repeating: 15, count: 8) + [60, 60])
        XCTAssertEqual(checks, 10)
    }

    @MainActor func testCancellationDuringWaitNeverStartsAnotherRequest() async {
        var checks = 0
        await AgentResponsePolling.run(check: { checks += 1 }, wait: { _ in throw CancellationError() })
        XCTAssertEqual(checks, 0)
    }

    func testNoPollingWhileBackgroundOfflineSignedOutOrAlreadyAnswered() {
        let waiting = AgentResponsePolling.Scope(accountToken: "session", active: true, online: true, requests: ["food:pending"])
        XCTAssertTrue(waiting.shouldPoll)
        for stopped in [
            AgentResponsePolling.Scope(accountToken: "session", active: false, online: true, requests: waiting.requests),
            .init(accountToken: "session", active: true, online: false, requests: waiting.requests),
            .init(accountToken: "", active: true, online: true, requests: waiting.requests),
            .init(accountToken: "session", active: true, online: true, requests: [])
        ] { XCTAssertFalse(stopped.shouldPoll) }
    }
}
