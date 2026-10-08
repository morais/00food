import Foundation

enum WatchDisk {
    static var directory: URL {
        let group = Bundle.main.object(forInfoDictionaryKey: "FoodWatchAppGroup") as? String
        let root = group.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("00FoodWatch", isDirectory: true)
    }

    static func load<T: Decodable>(_ type: T.Type, name: String, in root: URL? = nil) throws -> T? {
        let file = (root ?? directory).appendingPathComponent(name + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: file))
    }

    static func save<T: Encodable>(_ value: T, name: String, in root: URL? = nil) throws {
        let folder = root ?? directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: folder.appendingPathComponent(name + ".json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
