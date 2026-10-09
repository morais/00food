import Foundation

struct WatchCommand: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case food, water, estimate, undo }
    var id = UUID().uuidString.lowercased()
    let accountId: String
    let kind: Kind
    let createdAt: Date
    let localDate: String
    let timeZone: String
    var food: FoodItem?
    var quantity: Double = 1
    var description: String?
    var undoTarget: String?
    var undoKind: Kind?
    var undoLocalDate: String?

    init(accountId: String, kind: Kind, at date: Date = Date()) {
        self.accountId = accountId
        self.kind = kind
        createdAt = date
        localDate = FoodDates.localDate(for: date)
        timeZone = TimeZone.current.identifier
    }

    func validate(at now: Date = Date()) throws {
        guard UUID(uuidString: id) != nil, !accountId.isEmpty,
              let zone = TimeZone(identifier: timeZone),
              createdAt <= now.addingTimeInterval(300), now.timeIntervalSince(createdAt) < 90 * 86400 else {
            throw WatchActionError(message: "This Watch action is too old or could not be read.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: createdAt)
        let expected = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        guard localDate == expected else { throw WatchActionError(message: "The food's date could not be read.") }
        switch kind {
        case .food:
            guard let food, UUID(uuidString: food.id) != nil, quantity.isFinite, (0.25...20).contains(quantity) else {
                throw WatchActionError(message: "Choose a food and a valid portion.")
            }
        case .estimate:
            let text = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty, text.count <= 2000 else {
                throw WatchActionError(message: "Describe the food in up to 2,000 characters.")
            }
        case .undo:
            guard let undoTarget, UUID(uuidString: undoTarget) != nil else {
                throw WatchActionError(message: "The action to undo could not be found.")
            }
        case .water: break
        }
    }

    var foodKcal: Int { food.map { max(1, Int((Double($0.kcal) * quantity).rounded())) } ?? 0 }
    var fruitVegPortions: Int { food.map { min(5, Int((Double($0.countedFruitVegPortions) * quantity).rounded())) } ?? 0 }
}

struct WatchActionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct WatchReceipt: Codable, Equatable, Identifiable {
    let id: String
    let accepted: Bool
    let error: String?
    let date: Date
}

struct WatchEstimate: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let state: String
}

struct WatchSnapshot: Codable, Equatable {
    var accountId: String?
    var ready = false
    var localDate = FoodDates.today()
    var timeZone = TimeZone.current.identifier
    var updatedAt = Date.distantPast
    var budgetKcal: Int? = nil
    var allowanceKcal: Int { budgetKcal ?? (targetKcal + activeKcal) }
    var targetKcal = 0
    var activeKcal = 0
    var consumedKcal = 0
    var waterMl = 0
    var fruitVegPortions = 0
    var allowanceReady = false
    var startMinutes = 7 * 60
    var endMinutes = 23 * 60
    var foods: [FoodItem] = []
    var estimates: [WatchEstimate] = []
    var loggedIds: [String] = []
    var receipts: [WatchReceipt] = []

    func isCurrent(at date: Date = Date()) -> Bool {
        localDate == FoodDates.localDate(for: date) && timeZone == TimeZone.current.identifier
    }
}

struct WatchTransferState: Codable {
    var snapshot: WatchSnapshot?
    var commands: [WatchCommand] = []
    var cancelledIds: [String] = []

    // Apply only actions the phone has not included in its acknowledged state.
    // A log may arrive in a snapshot before its receipt; loggedIds avoids a
    // momentary double count in that case.
    func balance(at now: Date = Date()) -> WatchSnapshot? {
        guard var result = snapshot, result.ready, result.isCurrent(at: now) else { return nil }
        let receipts = Set(result.receipts.map(\.id))
        let logs = Set(result.loggedIds)
        let unconfirmed = commands.filter { $0.accountId == result.accountId && !receipts.contains($0.id) }
        let undone = Set(cancelledIds + unconfirmed.filter { $0.kind == .undo }.compactMap(\.undoTarget))
        for command in unconfirmed where command.localDate == result.localDate {
            if command.kind == .undo, let target = command.undoTarget,
               command.undoLocalDate == result.localDate {
                if command.undoKind == .food && logs.contains(target) {
                    result.consumedKcal -= command.foodKcal
                    result.fruitVegPortions -= command.fruitVegPortions
                } else if command.undoKind == .water && result.receipts.contains(where: { $0.id == target && $0.accepted }) {
                    result.waterMl -= 250
                }
                continue
            }
            guard !undone.contains(command.id) else { continue }
            switch command.kind {
            case .food where !logs.contains(command.id):
                result.consumedKcal += command.foodKcal
                result.fruitVegPortions += command.fruitVegPortions
            case .water: result.waterMl += 250
            default: break
            }
        }
        result.consumedKcal = max(0, result.consumedKcal)
        result.waterMl = max(0, result.waterMl)
        result.fruitVegPortions = min(5, max(0, result.fruitVegPortions))
        return result
    }

    mutating func receive(_ update: WatchSnapshot) -> [WatchReceipt] {
        // Messages and application contexts can arrive out of order.
        if let snapshot, snapshot.updatedAt > update.updatedAt { return [] }
        snapshot = update
        let ids = Set(commands.map(\.id))
        let matched = update.receipts.filter { ids.contains($0.id) }
        let completed = Set(matched.map(\.id))
        commands.removeAll { completed.contains($0.id) }
        return matched
    }
}

struct WatchInboxState: Codable {
    var pending: [WatchCommand] = []
    var completed: [WatchCommand] = []
    var receipts: [WatchReceipt] = []
    var cancelledIds: [String] = []

    mutating func enqueue(_ command: WatchCommand) {
        guard !receipts.contains(where: { $0.id == command.id }),
              !pending.contains(where: { $0.id == command.id }) else { return }
        pending.append(command)
    }
}
