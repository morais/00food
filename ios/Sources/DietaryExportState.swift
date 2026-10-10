import Foundation

struct DietaryExportState: Codable {
    var enabledAt: Date
    var exported: [String: String] = [:] // Log ID to local day, for matching deletions.

    static func enrolling(existing: DietaryExportState?, authorized: Bool,
                          now: Date = Date()) -> DietaryExportState? {
        // Keep receipts across temporary revocations; never enroll a denied user.
        if let existing { return existing }
        return authorized ? DietaryExportState(enabledAt: now) : nil
    }

    func shouldExport(_ log: FoodLog) -> Bool {
        guard let date = FoodDates.parseTimestamp(log.createdAt ?? log.loggedAt) else { return false }
        return date >= enabledAt && log.kcal > 0 && exported[log.id] == nil
    }
}
