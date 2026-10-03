import Foundation
import Observation
import Security

struct FoodServiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct ServerError: Decodable { var error: String }
private struct LoginResponse: Decodable {
    var token: String
    var tenant: Tenant
    struct Tenant: Decodable { var id: String; var email: String? }
}
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
    var busy = false
    var message: String?
    private(set) var token: String
    private let baseURL: String
    private static let tokenService = "00food.api-token"

    init() {
        baseURL = (Bundle.main.object(forInfoDictionaryKey: "FoodServerBaseURL") as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        token = Self.readToken()
        accountEmail = UserDefaults.standard.string(forKey: "accountEmail")
    }

    var signedIn: Bool { !token.isEmpty }
    var mcpAddress: String { baseURL + "/mcp" }
    var todaysLogs: [FoodLog] { logs.filter { $0.localDate == FoodDates.today() }.sorted { $0.loggedAt > $1.loggedAt } }
    var consumedToday: Int { todaysLogs.reduce(0) { $0 + $1.kcal } }
    var recentFoods: [FoodItem] {
        foods.sorted {
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
        accountEmail = response.tenant.email
        UserDefaults.standard.set(accountEmail, forKey: "accountEmail")
        try await refresh()
    }

    func refresh() async throws {
        guard signedIn else { return }
        let snapshot: FoodSnapshot = try await call("/v1/snapshot")
        profile = snapshot.profile
        foods = snapshot.foods
        logs = snapshot.logs
        estimations = snapshot.estimations
    }

    func saveProfile(_ input: FoodProfile) async throws {
        let response: ProfileResponse = try await call("/v1/profile", method: "PUT", body: [
            "heightCm": input.heightCm, "weightKg": input.weightKg,
            "estimateProfile": input.estimateProfile, "deficitKcal": input.deficitKcal,
        ] as [String: Any])
        profile = response.profile
    }

    func createFood(name: String, serving: String, kcal: Int, source: String = "manual") async throws -> FoodItem {
        let response: FoodResponse = try await call("/v1/foods", method: "POST", body: [
            "id": UUID().uuidString.lowercased(), "name": name, "serving": serving,
            "kcal": kcal, "source": source,
        ] as [String: Any])
        foods.insert(response.food, at: 0)
        return response.food
    }

    func log(_ food: FoodItem, quantity: Double = 1) async throws {
        let response: LogResponse = try await call("/v1/logs", method: "POST", body: [
            "id": UUID().uuidString.lowercased(), "foodId": food.id,
            "quantity": quantity, "localDate": FoodDates.today(),
        ] as [String: Any])
        logs.insert(response.log, at: 0)
        if let index = foods.firstIndex(where: { $0.id == food.id }) {
            foods[index].useCount += 1
            foods[index].lastUsedAt = response.log.loggedAt
        }
        message = "Logged \(food.name)"
    }

    func deleteLog(_ log: FoodLog) async throws {
        let _: OKResponse = try await call("/v1/logs/\(log.id)", method: "DELETE")
        logs.removeAll { $0.id == log.id }
        if let index = foods.firstIndex(where: { $0.id == log.foodId }) {
            foods[index].useCount = max(0, foods[index].useCount - 1)
        }
    }

    func requestEstimate(description: String, photo: Data?) async throws {
        let response: EstimationResponse = try await call("/v1/estimations", method: "POST", body: [
            "id": UUID().uuidString.lowercased(), "description": description,
            "localDate": FoodDates.today(),
        ])
        if let photo {
            do { try await uploadPhoto(photo, for: response.estimation.id) }
            catch {
                // Keep the text request visible if the photo upload fails.
                estimations.insert(response.estimation, at: 0)
                throw error
            }
        }
        try await refresh()
    }

    func updateProposal(id: String, name: String, serving: String, kcal: Int) async throws {
        let _: EstimationResponse = try await call("/v1/estimations/\(id)/proposal", method: "PUT", body: [
            "name": name, "serving": serving, "kcal": kcal, "note": "Adjusted after review",
        ] as [String: Any])
    }

    func accept(_ estimation: PendingEstimation) async throws {
        let _: AcceptedResponse = try await call("/v1/estimations/\(estimation.id)/accept", method: "POST")
        try await refresh()
    }

    func deleteEstimation(_ estimation: PendingEstimation) async throws {
        let _: OKResponse = try await call("/v1/estimations/\(estimation.id)", method: "DELETE")
        estimations.removeAll { $0.id == estimation.id }
    }

    func refreshConnections() async throws {
        let response: ConnectionsResponse = try await call("/v1/account/mcp-connections")
        connections = response.connections
    }

    func revokeConnection(_ connection: MCPConnection) async throws {
        let _: OKResponse = try await call("/v1/account/mcp-connections/\(connection.id)", method: "DELETE")
        connections.removeAll { $0.id == connection.id }
    }

    func signOut() async {
        let _: OKResponse? = try? await call("/v1/auth/logout", method: "POST")
        Self.deleteToken()
        token = ""
        accountEmail = nil
        UserDefaults.standard.removeObject(forKey: "accountEmail")
        profile = nil
        foods = []
        logs = []
        estimations = []
        connections = []
    }

    func deleteAccount(identityToken: String, code: String, nonce: String) async throws {
        let _: OKResponse = try await call("/v1/auth/delete-account", method: "POST", body: [
            "identityToken": identityToken, "authorizationCode": code, "nonce": nonce,
        ])
        Self.deleteToken()
        token = ""
        accountEmail = nil
        UserDefaults.standard.removeObject(forKey: "accountEmail")
        profile = nil
        foods = []
        logs = []
        estimations = []
        connections = []
    }

    private func uploadPhoto(_ data: Data, for id: String) async throws {
        guard let url = URL(string: baseURL + "/v1/estimations/\(id)/photo") else {
            throw FoodServiceError(message: "Server address is missing")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (result, response) = try await URLSession.shared.data(for: request)
        try check(response, data: result)
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
            throw FoodServiceError(message: detail)
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
