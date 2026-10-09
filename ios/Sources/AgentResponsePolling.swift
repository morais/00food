import Foundation

enum AgentResponsePolling {
    struct Scope: Equatable {
        let accountToken: String
        let active: Bool
        let online: Bool
        let requests: [String]

        var shouldPoll: Bool { active && online && !accountToken.isEmpty && !requests.isEmpty }
    }

    @MainActor static func run(
        check: () async -> Void,
        now: () -> Date = { Date() },
        wait: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async {
        let startedAt = now()
        while !Task.isCancelled {
            // Stay responsive to a new request, then ease off if the agent takes longer.
            let interval: TimeInterval = now().timeIntervalSince(startedAt) < 120 ? 15 : 60
            do { try await wait(interval) } catch { return }
            guard !Task.isCancelled else { return }
            await check()
        }
    }
}
