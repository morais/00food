import Foundation
import Network
import Observation
import Security

struct FoodServiceError: LocalizedError {
    let message: String
    var status: Int? = nil
    var errorDescription: String? { message }
}

private struct ServerError: Decodable { var error: String }
private struct LoginResponse: Decodable {
    var token: String
    var tenant: Tenant
    struct Tenant: Decodable { var id: String; var email: String? }
}
private struct MeResponse: Decodable { var id: String? }
private struct FoodResponse: Decodable { var food: FoodItem }
private struct LogResponse: Decodable { var log: FoodLog }
private struct ProfileResponse: Decodable { var profile: FoodProfile }
private struct EstimationResponse: Decodable { var estimation: PendingEstimation }
private struct OKResponse: Decodable { var ok: Bool? }
private struct AcceptedResponse: Decodable { var foodId: String; var logId: String }
private struct DailyFeedbackResponse: Decodable { var request: DailyFeedbackRequest }
private struct PushRegistrationResponse: Decodable { var ok: Bool; var enabled: Bool }

struct MCPConnection: Decodable, Identifiable {
    var id: String
    var clientName: String
    var scopes: [String]
    var connectedAt: String
    var lastUsedAt: String?
    var expiresAt: String
    var activeEvents: [String]?
}
private struct ConnectionsResponse: Decodable { var connections: [MCPConnection] }

@MainActor @Observable final class FoodStore {
    var profile: FoodProfile?
    var foods: [FoodItem] = []
    var logs: [FoodLog] = []
    var estimations: [PendingEstimation] = []
    var dailyFeedback: [DailyFeedbackRequest] = []
    var dailyFeedbackEnabled = false
    var connections: [MCPConnection] = []
    var hasLoadedConnections = false
    var accountEmail: String?
    var accountId: String?
    var startedAt: String?
    var busy = false
    var message: String?
    var syncError: String?
    var isOffline = false
    var isSyncing = false
    var hasLoadedSnapshot = false
    private(set) var token: String
    private let baseURL: String
    private var operations: [OfflineFoodOperation] = []
    private var retryTask: Task<Void, Never>?
    /// The server's tag for the snapshot last applied, and the session it
    /// belongs to. Kept in memory only, so each launch starts with a full load.
    private var snapshotTag: (token: String, etag: String)?
    /// Launch and foreground fire several overlapping refresh triggers; a
    /// successful sync within this window satisfies the rest.
    private static let refreshInterval: TimeInterval = 30
    private var lastSnapshotAt: Date?
    private var lastConnectionsAt: Date?
    private var pathMonitorPrimed = false
    private let pathMonitor = NWPathMonitor()
    private static let tokenService = "00food.api-token"
    /// Sessions signed out while offline, revoked on the server once a connection returns.
    private static let pendingRevocationService = "00food.pending-revocations"

    init() {
        baseURL = (Bundle.main.object(forInfoDictionaryKey: "FoodServerBaseURL") as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        token = Self.readToken()
        accountEmail = UserDefaults.standard.string(forKey: "accountEmail")
        if !token.isEmpty, let saved = try? OfflineFoodDisk.load(for: token) {
            apply(saved.snapshot)
            operations = saved.operations
            hasLoadedSnapshot = true
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isOffline = path.status != .satisfied
                if path.status == .satisfied { await self.revokePendingSessions() }
                // The first callback reports the launch state; the app's own launch refresh covers it.
                defer { self.pathMonitorPrimed = true }
                guard self.pathMonitorPrimed else { return }
                if path.status == .satisfied && self.signedIn { try? await self.refresh(force: true) }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "00food.network"))
    }

    var signedIn: Bool { !token.isEmpty }
    var pendingSyncCount: Int { operations.count }
    var mcpAddress: String { baseURL + "/mcp" }
    var accountStartedAt: Date? { FoodDates.parseTimestamp(startedAt) }
    var todaysLogs: [FoodLog] { logs(on: Date()) }
    var consumedToday: Int { todaysLogs.reduce(0) { $0 + $1.kcal } }
    var fruitVegToday: Int { min(5, todaysLogs.reduce(0) { $0 + $1.countedFruitVegPortions }) }
    var pendingDailyFeedbackCount: Int { dailyFeedback.filter { $0.state == "pending" }.count }
    var pendingAgentResponseKeys: [String] {
        let food = estimations.filter { $0.state == "pending" || $0.state == "uploading" }
            .map { "food:\($0.id):\($0.updatedAt)" }
        let days = dailyFeedback.filter { $0.state == "pending" }
            .map { "day:\($0.id):\($0.updatedAt)" }
        return (food + days).sorted()
    }
    var missingDailyFeedbackCount: Int { missingDailyFeedbackDates(includeHistory: true).count }
    var dailyFeedbackEnabledAt: String? {
        guard let accountId else { return nil }
        return UserDefaults.standard.string(forKey: "dailyFeedback.enabledAt.\(accountId)")
    }

    func setDailyFeedbackEnabled(_ enabled: Bool) {
        guard let accountId else { return }
        dailyFeedbackEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "dailyFeedback.enabled.\(accountId)")
        if enabled {
            UserDefaults.standard.set(FoodDates.today(), forKey: "dailyFeedback.enabledAt.\(accountId)")
        }
    }

    func requestDailyFeedback(_ upload: DailyFeedbackUpload) throws {
        guard !dailyFeedback.contains(where: { $0.localDate == upload.localDate }) else { return }
        let now = Self.now()
        let request = DailyFeedbackRequest(id: upload.id, localDate: upload.localDate,
                                           state: "pending", feedback: nil,
                                           createdAt: now, updatedAt: now)
        try stage(.requestDailyFeedback(upload)) {
            dailyFeedback.append(request)
            dailyFeedback.sort { $0.localDate > $1.localDate }
        }
    }

    func requestMissingDailyFeedback(using health: HealthEnergy, includeHistory: Bool,
                                    requireAccessibleHealth: Bool = false) async throws -> Int {
        let dates = missingDailyFeedbackDates(includeHistory: includeHistory)
        guard let first = dates.first, let last = dates.last else { return 0 }
        let calendar = Calendar.current
        let healthStart = calendar.date(byAdding: .day, value: -6, to: first) ?? first
        let accountToken = token
        let healthHistory = try await health.dailyFeedbackHealth(from: healthStart, through: last,
                                                                requireAccessibleData: requireAccessibleHealth)
        try Task.checkCancellation()
        guard token == accountToken, includeHistory || dailyFeedbackEnabled else { return 0 }
        let timeZone = TimeZone.current.identifier
        var queued = 0
        for date in dates {
            let key = FoodDates.localDate(for: date)
            let firstHealthDate = FoodDates.localDate(for:
                calendar.date(byAdding: .day, value: -6, to: date) ?? date)
            let healthDays = healthHistory.filter { $0.localDate >= firstHealthDate && $0.localDate <= key }
            let upload = DailyFeedbackUpload(id: UUID().uuidString.lowercased(), localDate: key,
                                             timeZone: timeZone, healthDays: healthDays)
            guard !dailyFeedback.contains(where: { $0.localDate == key }) else { continue }
            try requestDailyFeedback(upload)
            queued += 1
        }
        return queued
    }

    func canRequestDailyFeedback(on date: Date) -> Bool {
        let key = FoodDates.localDate(for: date)
        return missingDailyFeedbackDates(includeHistory: true).contains {
            FoodDates.localDate(for: $0) == key
        }
    }

    @discardableResult
    func requestDailyFeedback(on date: Date, using health: HealthEnergy) async throws -> Bool {
        guard canRequestDailyFeedback(on: date) else { return false }
        let calendar = Calendar.current
        let first = calendar.date(byAdding: .day, value: -6, to: date) ?? date
        let key = FoodDates.localDate(for: date)
        let firstKey = FoodDates.localDate(for: first)
        let healthDays = try await health.dailyFeedbackHealth(from: first, through: date)
            .filter { $0.localDate >= firstKey && $0.localDate <= key }
        guard canRequestDailyFeedback(on: date) else { return false }
        try requestDailyFeedback(DailyFeedbackUpload(id: UUID().uuidString.lowercased(),
            localDate: key, timeZone: TimeZone.current.identifier, healthDays: healthDays))
        return true
    }

    private func missingDailyFeedbackDates(includeHistory: Bool) -> [Date] {
        guard signedIn, hasLoadedSnapshot else { return [] }
        if !includeHistory && !dailyFeedbackEnabled { return [] }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let firstCompleted = calendar.date(byAdding: .day, value: -1, to: today),
              let accountStart = accountStartedAt.map({ calendar.startOfDay(for: $0) }) else { return [] }
        let dayLimit = includeHistory ? 90 : 7
        guard let limitStart = calendar.date(byAdding: .day, value: -dayLimit, to: today) else { return [] }
        // October 3 was cleared as a test day; October 4 is this app's first real day.
        let firstRealDay = FoodDates.parseLocalDate("2026-10-04") ?? accountStart
        var earliest = max(max(accountStart, limitStart), firstRealDay)
        if !includeHistory {
            guard let enabledAt = dailyFeedbackEnabledAt.flatMap(FoodDates.parseLocalDate),
                  let firstEnabledDay = calendar.date(byAdding: .day, value: -1, to: enabledAt) else { return [] }
            earliest = max(earliest, firstEnabledDay)
        }
        guard earliest <= firstCompleted else { return [] }
        let count = (calendar.dateComponents([.day], from: earliest, to: firstCompleted).day ?? 0) + 1
        let existing = Set(dailyFeedback.map(\.localDate))
        return (0..<count).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: earliest),
                  !existing.contains(FoodDates.localDate(for: day)) else { return nil }
            return day
        }
    }
    func logs(on date: Date) -> [FoodLog] {
        let day = FoodDates.localDate(for: date)
        return logs.filter { $0.localDate == day }.sorted { $0.loggedAt > $1.loggedAt }
    }
    var recentFoods: [FoodItem] {
        foods.filter { $0.useCount > 0 && $0.dismissedAt == nil }.sorted {
            if $0.useCount != $1.useCount { return $0.useCount > $1.useCount }
            return ($0.lastUsedAt ?? "") > ($1.lastUsedAt ?? "")
        }
    }

    func signIn(identityToken: String, code: String, nonce: String) async throws {
        let response: LoginResponse = try await call("/v1/auth/apple", method: "POST", body: [
            "identityToken": identityToken, "authorizationCode": code, "nonce": nonce,
        ], authenticated: false)
        try Self.saveToken(response.token)
        token = response.token
        lastSnapshotAt = nil
        lastConnectionsAt = nil
        apply(FoodSnapshot(startedAt: nil, profile: nil, foods: [], logs: [], estimations: []))
        operations = []
        hasLoadedSnapshot = false
        accountEmail = response.tenant.email
        accountId = response.tenant.id
        UserDefaults.standard.set(accountEmail, forKey: "accountEmail")
        try await refresh(force: true)
    }

    /// Syncs queued changes and reloads the snapshot. Without `force`, a call
    /// within `refreshInterval` of the last successful load is skipped unless
    /// local changes are waiting to sync.
    func refresh(force: Bool = false, quiet: Bool = false) async throws {
        guard signedIn, !isSyncing else { return }
        if !force, operations.isEmpty, let last = lastSnapshotAt,
           Date().timeIntervalSince(last) < Self.refreshInterval { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            while true {
                while let operation = operations.first {
                    try Task.checkCancellation()
                    try await replay(operation)
                    operations.removeFirst()
                    try persist()
                }
                let fetched = try await fetchSnapshot()
                try Task.checkCancellation()
                if !operations.isEmpty { continue }
                if accountId == nil {
                    let me: MeResponse = try await call("/v1/me")
                    accountId = me.id
                }
                // nil means 304: everything shown already matches the server.
                if let snapshot = fetched.snapshot {
                    apply(snapshot)
                    hasLoadedSnapshot = true
                    try persist()
                }
                snapshotTag = fetched.etag.map { (token, $0) }
                lastSnapshotAt = Date()
                syncError = nil
                isOffline = false
                retryTask?.cancel()
                retryTask = nil
                return
            }
        } catch {
            if Task.isCancelled { return }
            if Self.isConnectionError(error) {
                if !quiet { isOffline = true }
                scheduleRetry()
            }
            else if !quiet { syncError = error.localizedDescription }
        }
    }

    // A staged operation may already have started a sync. Background work must
    // wait for that sync before iOS suspends the app, so the MCP event is sent.
    func refreshAndWait(quiet: Bool = false) async throws {
        while isSyncing { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
        let previousCheck = lastSnapshotAt
        try await refresh(force: true, quiet: quiet)
        try Task.checkCancellation()
        if lastSnapshotAt == previousCheck || isOffline || syncError != nil || pendingSyncCount > 0 {
            throw FoodServiceError(message: "Daily feedback is waiting for a successful sync")
        }
    }

    func registerPushDevice(installationId: String, deviceToken: String, environment: String) async throws {
        let _: PushRegistrationResponse = try await call("/v1/push/device", method: "PUT", body: [
            "installationId": installationId, "deviceToken": deviceToken, "environment": environment,
        ])
    }

    func saveProfile(_ input: FoodProfile) async throws {
        var local = input
        local.updatedAt = Self.now()
        try stage(.saveProfile(local)) { profile = local }
    }

    func createFood(name: String, serving: String, kcal: Int,
                    fruitVegPortions: Int = 0, source: String = "manual") async throws -> FoodItem {
        let now = Self.now()
        let food = FoodItem(id: UUID().uuidString.lowercased(), name: name, serving: serving,
                            kcal: kcal, source: source, useCount: 0, lastUsedAt: nil,
                            dismissedAt: nil, createdAt: now, updatedAt: now,
                            fruitVegPortions: fruitVegPortions)
        try stage(.createFood(food)) { foods.insert(food, at: 0) }
        return food
    }

    func log(_ food: FoodItem, quantity: Double = 1, id: String = UUID().uuidString.lowercased(),
             loggedAt: Date = Date(), localDate: String? = nil) async throws {
        guard !logs.contains(where: { $0.id == id }) else { return }
        let log = FoodLog(id: id, foodId: food.id,
                          foodName: food.name, serving: food.serving, quantity: quantity,
                          kcal: max(1, Int((Double(food.kcal) * quantity).rounded())),
                          localDate: localDate ?? FoodDates.localDate(for: loggedAt),
                          loggedAt: ISO8601DateFormatter().string(from: loggedAt),
                          fruitVegPortions: min(5, Int((Double(food.countedFruitVegPortions) * quantity).rounded())))
        try stage(.log(log)) {
            logs.insert(log, at: 0)
            if let index = foods.firstIndex(where: { $0.id == food.id }) {
                foods[index].useCount += 1
                foods[index].lastUsedAt = log.loggedAt
                foods[index].dismissedAt = nil
            }
        }
        message = "Logged \(food.name)"
    }

    func dismissFromFrequent(_ food: FoodItem) async throws {
        try stage(.dismissFood(food.id)) {
            if let index = foods.firstIndex(where: { $0.id == food.id }) { foods[index].dismissedAt = Self.now() }
        }
    }

    func setFruitVegPortions(_ portions: Int, for food: FoodItem) throws {
        guard (0...5).contains(portions) else { throw FoodServiceError(message: "Choose 0–5 portions") }
        try stage(.setFruitVegPortions(food.id, portions)) {
            if let index = foods.firstIndex(where: { $0.id == food.id }) {
                foods[index].fruitVegPortions = portions
                foods[index].updatedAt = Self.now()
            }
            for index in logs.indices where logs[index].foodId == food.id {
                logs[index].fruitVegPortions = min(5, Int((Double(portions) * logs[index].quantity).rounded()))
            }
        }
    }

    func deleteLog(_ log: FoodLog) async throws {
        try stage(.deleteLog(log.id)) {
            logs.removeAll { $0.id == log.id }
            if let index = foods.firstIndex(where: { $0.id == log.foodId }) {
                foods[index].useCount = max(0, foods[index].useCount - 1)
            }
        }
    }

    func requestEstimate(description: String, photo: Data?, id: String = UUID().uuidString.lowercased(),
                         localDate: String? = nil) async throws {
        guard !estimations.contains(where: { $0.id == id }) else { return }
        let now = Self.now()
        let estimation = PendingEstimation(id: id, description: description,
                                           hasPhoto: photo != nil, state: "uploading", proposedName: nil,
                                           proposedServing: nil, proposedKcal: nil, agentNote: nil,
                                           localDate: localDate ?? FoodDates.today(), createdAt: now, updatedAt: now)
        try stage(.estimate(estimation, photo)) { estimations.insert(estimation, at: 0) }
    }

    func updateProposal(id: String, name: String, serving: String, kcal: Int,
                        fruitVegPortions: Int) async throws {
        let _: EstimationResponse = try await call("/v1/estimations/\(id)/proposal", method: "PUT", body: [
            "name": name, "serving": serving, "kcal": kcal, "fruitVegPortions": fruitVegPortions,
            "note": "Adjusted after review",
        ] as [String: Any])
    }

    func clarifyEstimate(id: String, text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 1000 else {
            throw FoodServiceError(message: "Clarification must be between 1 and 1,000 characters")
        }
        let clarificationId = UUID().uuidString.lowercased()
        try stage(.clarifyEstimate(id, clarificationId, trimmed)) {
            if let index = estimations.firstIndex(where: { $0.id == id }) {
                estimations[index].clarification = trimmed
                estimations[index].state = "pending"
                estimations[index].updatedAt = Self.now()
            }
        }
    }

    func accept(_ estimation: PendingEstimation) async throws {
        let _: AcceptedResponse = try await call("/v1/estimations/\(estimation.id)/accept", method: "POST")
        try await refresh(force: true)
    }

    func deleteEstimation(_ estimation: PendingEstimation) async throws {
        try stage(.deleteEstimate(estimation.id)) { estimations.removeAll { $0.id == estimation.id } }
    }

    func refreshConnections(force: Bool = false) async throws {
        if !force, let last = lastConnectionsAt, Date().timeIntervalSince(last) < Self.refreshInterval { return }
        let response: ConnectionsResponse = try await call("/v1/account/mcp-connections")
        connections = response.connections
        hasLoadedConnections = true
        lastConnectionsAt = Date()
    }

    func revokeConnection(_ connection: MCPConnection) async throws {
        let _: OKResponse = try await call("/v1/account/mcp-connections/\(connection.id)", method: "DELETE")
        connections.removeAll { $0.id == connection.id }
    }

    func signOut() async throws {
        guard !isSyncing else {
            throw FoodServiceError(message: "Sync is finishing. Try signing out again in a moment.")
        }
        guard operations.isEmpty else {
            throw FoodServiceError(message: "\(operations.count) change(s) are waiting to sync. Connect to the internet before signing out so they are not lost.")
        }
        do {
            let _: OKResponse = try await call("/v1/auth/logout", method: "POST")
        } catch let error as FoodServiceError where error.status == 401 {
            // The server already considers this session ended.
        } catch {
            Self.queueRevocation(of: token)
        }
        try OfflineFoodDisk.clear(for: token)
        Self.deleteToken()
        if let accountId { Self.forgetAccountDefaults(accountId) }
        token = ""
        accountEmail = nil
        accountId = nil
        startedAt = nil
        UserDefaults.standard.removeObject(forKey: "accountEmail")
        profile = nil
        foods = []
        logs = []
        estimations = []
        dailyFeedback = []
        connections = []
        hasLoadedConnections = false
        syncError = nil
        hasLoadedSnapshot = false
        lastSnapshotAt = nil
        lastConnectionsAt = nil
    }

    func deleteAccount(identityToken: String, code: String, nonce: String) async throws {
        guard !isSyncing else {
            throw FoodServiceError(message: "Sync is finishing. Try deleting the account again in a moment.")
        }
        let _: OKResponse = try await call("/v1/auth/delete-account", method: "POST", body: [
            "identityToken": identityToken, "authorizationCode": code, "nonce": nonce,
        ])
        try OfflineFoodDisk.clear(for: token)
        Self.deleteToken()
        if let accountId { Self.forgetAccountDefaults(accountId) }
        token = ""
        accountEmail = nil
        accountId = nil
        startedAt = nil
        UserDefaults.standard.removeObject(forKey: "accountEmail")
        profile = nil
        foods = []
        logs = []
        estimations = []
        dailyFeedback = []
        connections = []
        hasLoadedConnections = false
        operations = []
        syncError = nil
        hasLoadedSnapshot = false
        lastSnapshotAt = nil
        lastConnectionsAt = nil
    }

    /// Settings and Health export bookkeeping are stored per account in
    /// UserDefaults, which is backed up; none of it should outlive the session.
    private static func forgetAccountDefaults(_ accountId: String) {
        for key in ["dailyFeedback.enabled.\(accountId)", "dailyFeedback.enabledAt.\(accountId)"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        HealthEnergy.forgetDietaryExport(for: accountId)
    }

    private static func now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func isConnectionError(_ error: Error) -> Bool {
        error is URLError || (error as NSError).domain == NSURLErrorDomain
    }

    private func snapshot() -> FoodSnapshot {
        FoodSnapshot(accountId: accountId, startedAt: startedAt, profile: profile,
                     foods: foods, logs: logs, estimations: estimations,
                     dailyFeedback: dailyFeedback)
    }

    private func apply(_ snapshot: FoodSnapshot) {
        startedAt = snapshot.startedAt
        if let id = snapshot.accountId { accountId = id }
        profile = snapshot.profile
        foods = snapshot.foods
        logs = snapshot.logs
        estimations = snapshot.estimations
        dailyFeedback = snapshot.dailyFeedback ?? []
        dailyFeedbackEnabled = accountId.map { UserDefaults.standard.bool(forKey: "dailyFeedback.enabled.\($0)") } ?? false
    }

    private func persist() throws {
        try OfflineFoodDisk.save(OfflineFoodState(snapshot: snapshot(), operations: operations), for: token)
    }

    private func scheduleRetry() {
        guard retryTask == nil, !operations.isEmpty else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            try? await self.refresh()
        }
    }

    private func stage(_ operation: OfflineFoodOperation, update: () -> Void) throws {
        guard signedIn else { throw FoodServiceError(message: "Sign in before logging food") }
        let previous = snapshot()
        operations.append(operation)
        update()
        do { try persist() }
        catch {
            operations.removeLast()
            apply(previous)
            throw FoodServiceError(message: "Could not save this change on your iPhone: \(error.localizedDescription)")
        }
        Task { try? await refresh() }
    }

    private func replay(_ operation: OfflineFoodOperation) async throws {
        switch operation {
        case .saveProfile(let profile):
            let _: ProfileResponse = try await call("/v1/profile", method: "PUT", body: [
                "heightCm": profile.heightCm, "weightKg": profile.weightKg,
                "estimateProfile": profile.estimateProfile, "deficitKcal": profile.deficitKcal,
            ])
        case .createFood(let food):
            let _: FoodResponse = try await call("/v1/foods", method: "POST", body: [
                "id": food.id, "name": food.name, "serving": food.serving,
                "kcal": food.kcal, "fruitVegPortions": food.countedFruitVegPortions,
                "source": food.source,
            ])
        case .log(let log):
            let _: LogResponse = try await call("/v1/logs", method: "POST", body: [
                "id": log.id, "foodId": log.foodId, "quantity": log.quantity,
                "localDate": log.localDate, "loggedAt": log.loggedAt,
            ])
        case .dismissFood(let id):
            let _: FoodResponse = try await call("/v1/foods/\(id)/dismiss", method: "POST")
        case .setFruitVegPortions(let id, let portions):
            let _: FoodResponse = try await call("/v1/foods/\(id)/fruit-veg-portions", method: "PUT",
                                                 body: ["fruitVegPortions": portions])
        case .deleteLog(let id):
            do { let _: OKResponse = try await call("/v1/logs/\(id)", method: "DELETE") }
            catch let error as FoodServiceError where error.status == 404 { break }
        case .estimate(let estimation, let photo):
            // Multipart keeps the description and photo in one request without
            // base64 inflation, so the agent sees both together.
            let form = Self.multipartForm(fields: ["id": estimation.id, "description": estimation.description,
                                                   "localDate": estimation.localDate],
                                          jpeg: photo)
            let _: EstimationResponse = try await call("/v1/estimations", method: "POST", raw: form)
        case .clarifyEstimate(let estimationId, let clarificationId, let text):
            let _: EstimationResponse = try await call("/v1/estimations/\(estimationId)/clarifications",
                                                       method: "POST", body: ["id": clarificationId, "text": text])
        case .deleteEstimate(let id):
            do { let _: OKResponse = try await call("/v1/estimations/\(id)", method: "DELETE") }
            catch let error as FoodServiceError where error.status == 404 { break }
        case .requestDailyFeedback(let upload):
            let healthDays = upload.healthDays.map { day -> [String: Any] in
                ["localDate": day.localDate,
                 "activeKcal": day.activeKcal as Any? ?? NSNull(),
                 "restingKcal": day.restingKcal as Any? ?? NSNull(),
                 "waterMl": day.waterMl as Any? ?? NSNull(),
                 "weightKg": day.weightKg as Any? ?? NSNull(),
                 "bodyFatPercent": day.bodyFatPercent as Any? ?? NSNull()]
            }
            let _: DailyFeedbackResponse = try await call("/v1/daily-feedback", method: "POST", body: [
                "id": upload.id, "localDate": upload.localDate,
                "timeZone": upload.timeZone, "healthDays": healthDays,
            ])
        }
    }

    /// Retries the server-side logout for sessions that ended while offline, so
    /// a signed-out token does not stay valid until it expires.
    func revokePendingSessions() async {
        for pending in Self.pendingRevocations() {
            do {
                let _: OKResponse = try await call("/v1/auth/logout", method: "POST", bearer: pending)
            } catch let error as FoodServiceError where error.status == 401 {
                // Already invalid on the server.
            } catch {
                continue
            }
            Self.removePendingRevocation(pending)
        }
    }

    /// Loads /v1/snapshot, revalidating with the last tag when the local copy
    /// came from the server unchanged. Returns a nil snapshot on 304.
    private func fetchSnapshot() async throws -> (snapshot: FoodSnapshot?, etag: String?) {
        guard let url = URL(string: baseURL + "/v1/snapshot"), url.scheme == "https" || url.host == "localhost" else {
            throw FoodServiceError(message: "Server address is missing")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let tag = snapshotTag?.token == token && hasLoadedSnapshot ? snapshotTag?.etag : nil
        if let tag { request.setValue(tag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
        if tag != nil, (response as? HTTPURLResponse)?.statusCode == 304 { return (nil, etag ?? tag) }
        try check(response, data: data)
        return (try JSONDecoder().decode(FoodSnapshot.self, from: data), etag)
    }

    private func call<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                                     raw: (body: Data, contentType: String)? = nil,
                                     authenticated: Bool = true, bearer: String? = nil) async throws -> T {
        guard let url = URL(string: baseURL + path), url.scheme == "https" || url.host == "localhost" else {
            throw FoodServiceError(message: "Server address is missing")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if authenticated { request.setValue("Bearer \(bearer ?? token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else if let raw {
            request.setValue(raw.contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = raw.body
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func multipartForm(fields: [String: String], jpeg: Data?) -> (body: Data, contentType: String) {
        let boundary = "00food-\(UUID().uuidString)"
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        if let jpeg {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"photo.jpg\"\r\n")
            append("Content-Type: image/jpeg\r\n\r\n")
            body.append(jpeg)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        return (body, "multipart/form-data; boundary=\(boundary)")
    }

    private func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw FoodServiceError(message: "No server response") }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(ServerError.self, from: data).error) ?? "Server error (\(http.statusCode))"
            throw FoodServiceError(message: detail, status: http.statusCode)
        }
    }

    private static func readToken() -> String { readKeychain(tokenService) }

    private static func saveToken(_ token: String) throws {
        guard writeKeychain(tokenService, token) else {
            throw FoodServiceError(message: "Could not save the sign-in session")
        }
    }

    private static func deleteToken() { deleteKeychain(tokenService) }

    private static func pendingRevocations() -> [String] {
        readKeychain(pendingRevocationService).split(separator: "\n").map(String.init)
    }

    private static func queueRevocation(of token: String) {
        guard !token.isEmpty else { return }
        let tokens = pendingRevocations().filter { $0 != token } + [token]
        _ = writeKeychain(pendingRevocationService, tokens.suffix(10).joined(separator: "\n"))
    }

    private static func removePendingRevocation(_ token: String) {
        let tokens = pendingRevocations().filter { $0 != token }
        if tokens.isEmpty { deleteKeychain(pendingRevocationService) }
        else { _ = writeKeychain(pendingRevocationService, tokens.joined(separator: "\n")) }
    }

    private static func readKeychain(_ service: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func writeKeychain(_ service: String, _ value: String) -> Bool {
        deleteKeychain(service)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecValueData as String: Data(value.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func deleteKeychain(_ service: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
    }
}
