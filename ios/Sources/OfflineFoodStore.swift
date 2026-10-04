import CryptoKit
import Foundation

enum OfflineFoodOperation: Codable {
    case saveProfile(FoodProfile)
    case createFood(FoodItem)
    case log(FoodLog)
    case dismissFood(String)
    case deleteLog(String)
    case estimate(PendingEstimation, Data?)
    case deleteEstimate(String)
}

struct OfflineFoodState: Codable {
    var snapshot: FoodSnapshot
    var operations: [OfflineFoodOperation]
}

enum OfflineFoodDisk {
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("00Food", isDirectory: true)
    }

    private static func file(for token: String, in root: URL?) -> URL {
        let hash = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        return (root ?? directory).appendingPathComponent("food-\(hash).json")
    }

    static func load(for token: String, in root: URL? = nil) throws -> OfflineFoodState? {
        let url = file(for: token, in: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(OfflineFoodState.self, from: Data(contentsOf: url))
    }

    static func save(_ state: OfflineFoodState, for token: String, in root: URL? = nil) throws {
        try FileManager.default.createDirectory(at: root ?? directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: file(for: token, in: root), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func clear(for token: String, in root: URL? = nil) throws {
        let url = file(for: token, in: root)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
