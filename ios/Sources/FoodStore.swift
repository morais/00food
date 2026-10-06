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

struct MCPConnection: Decodable, Identifiable {
    var id: String
    var clientName: String
    var connectedAt: String
    var lastUsedAt: String?
    var expiresAt: String
}
private struct ConnectionsResponse: Decodable { var connections: [MCPConnection] }

@MainActor @Observable final class FoodStore {
    var profile: FoodProfile?
    var foods: [FoodItem] = []
    var logs: [FoodLog] = []
    var estimations: [PendingEstimation] = []
    var connections: [MCPConnection] = []
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
    private let pathMonitor = NWPathMonitor()
    private static let tokenService = "00food.api-token"

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
                if path.status == .satisfied && self.signedIn { try? await self.refresh() }
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
        apply(FoodSnapshot(startedAt: nil, profile: nil, foods: [], logs: [], estimations: []))
        operations = []
        hasLoadedSnapshot = false
        accountEmail = response.tenant.email
        accountId = response.tenant.id
        UserDefaults.standard.set(accountEmail, forKey: "accountEmail")
        try await refresh()
    }

    func refresh() async throws {
        guard signedIn, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            while true {
                while let operation = operations.first {
                    try await replay(operation)
                    operations.removeFirst()
                    try persist()
                }
                let snapshot: FoodSnapshot = try await call("/v1/snapshot")
                if !operations.isEmpty { continue }
                if accountId == nil {
                    let me: MeResponse = try await call("/v1/me")
                    accountId = me.id
                }
                apply(snapshot)
                hasLoadedSnapshot = true
                try persist()
                syncError = nil
                isOffline = false
                retryTask?.cancel()
                retryTask = nil
                return
            }
        } catch {
            if Self.isConnectionError(error) {
                isOffline = true
                scheduleRetry()
            }
            else { syncError = error.localizedDescription }
        }
    }

    func saveProfile(_ input: FoodProfile) async throws {
        var local = input
        local.updatedAt = Self.now()
        try stage(.saveProfile(local)) { profile = local }
    }

    func createFood(name: String, serving: String, kcal: Int, source: String = "manual") async throws -> FoodItem {
        let now = Self.now()
        let food = FoodItem(id: UUID().uuidString.lowercased(), name: name, serving: serving,
                            kcal: kcal, source: source, useCount: 0, lastUsedAt: nil,
                            dismissedAt: nil, createdAt: now, updatedAt: now)
        try stage(.createFood(food)) { foods.insert(food, at: 0) }
        return food
    }

    func log(_ food: FoodItem, quantity: Double = 1) async throws {
        let log = FoodLog(id: UUID().uuidString.lowercased(), foodId: food.id,
                          foodName: food.name, serving: food.serving, quantity: quantity,
                          kcal: max(1, Int((Double(food.kcal) * quantity).rounded())),
                          localDate: FoodDates.today(), loggedAt: Self.now())
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

    func deleteLog(_ log: FoodLog) async throws {
        try stage(.deleteLog(log.id)) {
            logs.removeAll { $0.id == log.id }
            if let index = foods.firstIndex(where: { $0.id == log.foodId }) {
                foods[index].useCount = max(0, foods[index].useCount - 1)
            }
        }
    }

    func requestEstimate(description: String, photo: Data?) async throws {
        let now = Self.now()
        let estimation = PendingEstimation(id: UUID().uuidString.lowercased(), description: description,
                                           hasPhoto: photo != nil, state: "uploading", proposedName: nil,
                                           proposedServing: nil, proposedKcal: nil, agentNote: nil,
                                           localDate: FoodDates.today(), createdAt: now, updatedAt: now)
        try stage(.estimate(estimation, photo)) { estimations.insert(estimation, at: 0) }
    }

    func updateProposal(id: String, name: String, serving: String, kcal: Int) async throws {
        let _: EstimationResponse = try await call("/v1/estimations/\(id)/proposal", method: "PUT", body: [
            "name": name, "serving": serving, "kcal": kcal, "note": "Adjusted after review",
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
        try await refresh()
    }

    func deleteEstimation(_ estimation: PendingEstimation) async throws {
        try stage(.deleteEstimate(estimation.id)) { estimations.removeAll { $0.id == estimation.id } }
    }

    func refreshConnections() async throws {
        let response: ConnectionsResponse = try await call("/v1/account/mcp-connections")
        connections = response.connections
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
        let _: OKResponse? = try? await call("/v1/auth/logout", method: "POST")
        try OfflineFoodDisk.clear(for: token)
        Self.deleteToken()
        token = ""
        accountEmail = nil
        accountId = nil
        startedAt = nil
        UserDefaults.standard.removeObject(forKey: "accountEmail")
        profile = nil
        foods = []
        logs = []
        estimations = []
        connections = []
        syncError = nil
        hasLoadedSnapshot = false
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
        token = ""
        accountEmail = nil
        accountId = nil
        startedAt = nil
        UserDefaults.standard.removeObject(forKey: "accountEmail")
        profile = nil
        foods = []
        logs = []
        estimations = []
        connections = []
        operations = []
        syncError = nil
        hasLoadedSnapshot = false
    }

    private static func now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func isConnectionError(_ error: Error) -> Bool {
        error is URLError || (error as NSError).domain == NSURLErrorDomain
    }

    private func snapshot() -> FoodSnapshot {
        FoodSnapshot(accountId: accountId, startedAt: startedAt, profile: profile,
                     foods: foods, logs: logs, estimations: estimations)
    }

    private func apply(_ snapshot: FoodSnapshot) {
        startedAt = snapshot.startedAt
        if let id = snapshot.accountId { accountId = id }
        profile = snapshot.profile
        foods = snapshot.foods
        logs = snapshot.logs
        estimations = snapshot.estimations
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
                "birthYear": profile.birthYear as Any? ?? NSNull(),
            ])
        case .createFood(let food):
            let _: FoodResponse = try await call("/v1/foods", method: "POST", body: [
                "id": food.id, "name": food.name, "serving": food.serving,
                "kcal": food.kcal, "source": food.source,
            ])
        case .log(let log):
            let _: LogResponse = try await call("/v1/logs", method: "POST", body: [
                "id": log.id, "foodId": log.foodId, "quantity": log.quantity,
                "localDate": log.localDate, "loggedAt": log.loggedAt,
            ])
        case .dismissFood(let id):
            let _: FoodResponse = try await call("/v1/foods/\(id)/dismiss", method: "POST")
        case .deleteLog(let id):
            do { let _: OKResponse = try await call("/v1/logs/\(id)", method: "DELETE") }
            catch let error as FoodServiceError where error.status == 404 { break }
        case .estimate(let estimation, let photo):
            var payload: [String: Any] = ["id": estimation.id, "description": estimation.description,
                                          "localDate": estimation.localDate]
            if let photo { payload["photoBase64"] = photo.base64EncodedString() }
            let _: EstimationResponse = try await call("/v1/estimations", method: "POST", body: payload)
        case .clarifyEstimate(let estimationId, let clarificationId, let text):
            let _: EstimationResponse = try await call("/v1/estimations/\(estimationId)/clarifications",
                                                       method: "POST", body: ["id": clarificationId, "text": text])
        case .deleteEstimate(let id):
            do { let _: OKResponse = try await call("/v1/estimations/\(id)", method: "DELETE") }
            catch let error as FoodServiceError where error.status == 404 { break }
        }
    }

    private func call<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                                     authenticated: Bool = true) async throws -> T {
        guard let url = URL(string: baseURL + path), url.scheme == "https" || url.host == "localhost" else {
            throw FoodServiceError(message: "Server address is missing")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if authenticated { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw FoodServiceError(message: "No server response") }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(ServerError.self, from: data).error) ?? "Server error (\(http.statusCode))"
            throw FoodServiceError(message: detail, status: http.statusCode)
        }
    }

    private static func readToken() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: tokenService,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func saveToken(_ token: String) throws {
        deleteToken()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: tokenService,
                                    kSecValueData as String: Data(token.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw FoodServiceError(message: "Could not save the sign-in session")
        }
    }

    private static func deleteToken() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: tokenService]
        SecItemDelete(query as CFDictionary)
    }
}
