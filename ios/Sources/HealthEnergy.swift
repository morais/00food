import Foundation
import HealthKit
import Observation

struct HealthMeasurePoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

struct RestingEnergySummary {
    let averageKcal: Int?
    let daysUsed: Int

    init(completedDayTotals: [Double]) {
        let totals = completedDayTotals.filter { $0.isFinite && $0 > 0 }
        daysUsed = totals.count
        averageKcal = totals.count >= 5
            ? Int((totals.reduce(0, +) / Double(totals.count)).rounded()) : nil
    }
}

private struct DietaryExportState: Codable {
    var enabledAt: Date
    var exported: [String: String] = [:] // Log ID to local day, for matching deletions.
}

@MainActor @Observable final class HealthEnergy {
    var activeKcal = 0
    var waterMlToday = 0
    var latestWeightKg: Double?
    var latestWeightDate: Date?
    var latestBodyFatPercent: Double?
    var latestBodyFatDate: Date?
    var weightHistory: [HealthMeasurePoint] = []
    var bodyFatHistory: [HealthMeasurePoint] = []
    var activeHistory: [HealthMeasurePoint] = []
    var restingAverageKcal: Int?
    var restingDaysUsed = 0
    var requested = UserDefaults.standard.bool(forKey: "healthRequested")
    var restingRequested = UserDefaults.standard.bool(forKey: "healthRestingRequested")
    var weightRequested = UserDefaults.standard.bool(forKey: "healthWeightRequested")
    var bodyFatRequested = UserDefaults.standard.bool(forKey: "healthBodyFatRequested")
    var waterRequested = UserDefaults.standard.bool(forKey: "healthWaterRequested")
    var errorMessage: String?
    var waterErrorMessage: String?
    var waterSaving = false
    private(set) var isRefreshing = false
    var hasLoadedAllowance = false
    var dietaryExportEnabled = false
    var dietaryErrorMessage: String?
    private var historyStart: Date?
    private var dietaryAccountId: String?
    private var dietarySyncing = false
    private var queuedDietaryLogs: [FoodLog]?
    private var waterDay = FoodDates.today()
    private var allowanceDay = FoodDates.today()
    private var waterRefreshID = UUID()
    private var waterRefreshCount = 0
    private var temporaryReadFailure = false
    private var temporaryWaterReadFailure = false
    private let store = HKHealthStore()
    private let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!
    private let restingEnergy = HKObjectType.quantityType(forIdentifier: .basalEnergyBurned)!
    private let dietaryEnergy = HKObjectType.quantityType(forIdentifier: .dietaryEnergyConsumed)!
    private let bodyMass = HKObjectType.quantityType(forIdentifier: .bodyMass)!
    private let bodyFat = HKObjectType.quantityType(forIdentifier: .bodyFatPercentage)!
    private let water = HKObjectType.quantityType(forIdentifier: .dietaryWater)!

    var available: Bool { HKHealthStore.isHealthDataAvailable() }
    var isRefreshingWater: Bool { waterRefreshCount > 0 }
    var allowanceIsReady: Bool { !available || !requested || (hasLoadedAllowance && !isRefreshing) }
    var dietaryExportAuthorized: Bool {
        available && store.authorizationStatus(for: dietaryEnergy) == .sharingAuthorized
    }

    var usableLatestWeightKg: Double? {
        guard let weight = latestWeightKg, weight.isFinite, (25...400).contains(weight) else { return nil }
        return weight
    }

    func effectiveRestingKcal(for profile: FoodProfile) -> Int {
        if let restingAverageKcal { return restingAverageKcal }
        var current = profile
        if let weight = usableLatestWeightKg { current.weightKg = weight }
        return current.restingKcal
    }

    func configureDietaryExport(accountId: String?) {
        guard dietaryAccountId != accountId else { return }
        dietaryAccountId = accountId
        dietaryExportEnabled = accountId.flatMap { Self.loadDietaryState(for: $0) } != nil
        dietaryErrorMessage = nil
    }

    func setHistoryStart(_ date: Date?) {
        let start = date.map { Calendar.current.startOfDay(for: $0) }
        if historyStart != start {
            historyStart = start
            weightHistory = []
            bodyFatHistory = []
            activeHistory = []
        }
    }

    func connect() async {
        guard available else {
            errorMessage = "Apple Health is not available on this device."
            return
        }
        do {
            try await requestReadAuthorization()
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    private func requestReadAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: [energy, restingEnergy, bodyMass, bodyFat, water])
        requested = true
        restingRequested = true
        weightRequested = true
        bodyFatRequested = true
        waterRequested = true
        for key in ["healthRequested", "healthRestingRequested", "healthWeightRequested", "healthBodyFatRequested", "healthWaterRequested"] {
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    func refresh() async {
        // Launch and foreground refresh from both RootView and HomeView. Join
        // the existing refresh so an older completion cannot overwrite it.
        if isRefreshing {
            while isRefreshing {
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return }
            }
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        await refreshValues()
        // A foreground transition can race with Health becoming readable after
        // unlock. Retry once quietly, without retrying permission/write errors.
        if temporaryReadFailure || temporaryWaterReadFailure {
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            await refreshValues()
        }
    }

    private func refreshValues() async {
        errorMessage = nil
        temporaryReadFailure = false
        if allowanceDay != FoodDates.today() {
            allowanceDay = FoodDates.today()
            activeKcal = 0
            hasLoadedAllowance = false
        }
        resetWaterForNewDay()
        guard available else { return }
        if !requested {
            if weightRequested { try? await refreshWeight() }
            if waterRequested { await refreshWater() }
            return
        }
        if !waterRequested {
            do {
                try await store.requestAuthorization(toShare: [], read: [water])
                waterRequested = true
                UserDefaults.standard.set(true, forKey: "healthWaterRequested")
            } catch { waterErrorMessage = error.localizedDescription }
        }
        if !restingRequested {
            do { try await requestReadAuthorization() }
            catch { errorMessage = error.localizedDescription; return }
        }
        do {
            let start = Calendar.current.startOfDay(for: Date())
            let today = HKQuery.predicateForSamples(withStart: start, end: Date())
            let active: Double
            do {
                active = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Double, Error>) in
                    let query = HKStatisticsQuery(quantityType: energy, quantitySamplePredicate: today,
                                                  options: .cumulativeSum) { _, statistics, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0) }
                    }
                    store.execute(query)
                }
            } catch {
                if Self.isNoData(error) { active = 0 }
                else { throw error }
            }
            activeKcal = max(0, Int(active.rounded()))
            let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: start) ?? start
            let restingDays = try await HealthQueryResult.read(noData: [HealthMeasurePoint]()) {
                try await dailyCumulativeEnergy(of: restingEnergy, from: sevenDaysAgo, to: start)
            }.filter { $0.value > 0 && $0.date < start }
            let restingSummary = RestingEnergySummary(completedDayTotals: restingDays.map(\.value))
            restingDaysUsed = restingSummary.daysUsed
            restingAverageKcal = restingSummary.averageKcal
            if let historyStart {
                let ninetyDaysAgo = Calendar.current.date(byAdding: .day, value: -89, to: start) ?? start
                activeHistory = try await HealthQueryResult.read(noData: [HealthMeasurePoint]()) {
                    try await dailyActiveEnergy(from: max(historyStart, ninetyDaysAgo))
                }
            }

            if weightRequested { try await refreshWeight() }
            if bodyFatRequested {
                let latest = try await HealthQueryResult.read(noData: Optional<HKQuantitySample>.none) {
                    try await newestSample(of: bodyFat)
                }
                latestBodyFatPercent = latest.map { $0.quantity.doubleValue(for: .percent()) * 100 }
                latestBodyFatDate = latest?.endDate
                if let historyStart {
                    bodyFatHistory = try await HealthQueryResult.read(noData: [HealthMeasurePoint]()) {
                        try await dailyHistory(of: bodyFat, from: historyStart, unit: .percent(), scale: 100)
                    }
                }
            }
            errorMessage = nil
            hasLoadedAllowance = allowanceDay == FoodDates.today()
        } catch {
            temporaryReadFailure = HealthQueryResult.isTemporarilyUnavailable(error)
            errorMessage = error.localizedDescription
        }
        if waterRequested { await refreshWater() }
    }

    private func refreshWeight() async throws {
        let latest = try await HealthQueryResult.read(noData: Optional<HKQuantitySample>.none) {
            try await newestSample(of: bodyMass)
        }
        latestWeightKg = latest?.quantity.doubleValue(for: .gramUnit(with: .kilo))
        latestWeightDate = latest?.endDate
        if let historyStart {
            weightHistory = try await HealthQueryResult.read(noData: [HealthMeasurePoint]()) {
                try await dailyHistory(of: bodyMass, from: historyStart, unit: .gramUnit(with: .kilo), scale: 1)
            }
        }
    }

    func refreshWater() async {
        resetWaterForNewDay()
        guard waterRequested && available else { return }
        let requestID = UUID()
        waterRefreshID = requestID
        waterRefreshCount += 1
        defer { waterRefreshCount -= 1 }
        waterErrorMessage = nil
        temporaryWaterReadFailure = false
        let requestedDay = FoodDates.today()
        let start = Calendar.current.startOfDay(for: Date())
        do {
            let milliliters = try await waterMilliliters(from: start, to: Date())
            guard waterRefreshID == requestID, requestedDay == FoodDates.today() else { return }
            waterMlToday = milliliters
            waterErrorMessage = nil
        } catch {
            guard waterRefreshID == requestID, requestedDay == FoodDates.today() else { return }
            temporaryWaterReadFailure = HealthQueryResult.isTemporarilyUnavailable(error)
            waterErrorMessage = error.localizedDescription
        }
    }

    func waterMl(on date: Date) async throws -> Int? {
        guard available, waterRequested else { return nil }
        let start = Calendar.current.startOfDay(for: date)
        guard let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return nil }
        return try await waterMilliliters(from: start, to: min(nextDay, Date()))
    }

    private func waterMilliliters(from start: Date, to end: Date) async throws -> Int {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
        do {
            let milliliters = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Double, Error>) in
                let query = HKStatisticsQuery(quantityType: water, quantitySamplePredicate: predicate,
                                              options: .cumulativeSum) { _, statistics, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning:
                        statistics?.sumQuantity()?.doubleValue(for: .literUnit(with: .milli)) ?? 0) }
                }
                store.execute(query)
            }
            return max(0, Int(milliliters.rounded()))
        } catch {
            if Self.isNoData(error) { return 0 }
            throw error
        }
    }

    private func resetWaterForNewDay() {
        let today = FoodDates.today()
        guard waterDay != today else { return }
        waterDay = today
        waterMlToday = 0
        waterErrorMessage = nil
    }

    private static func isNoData(_ error: Error) -> Bool {
        HealthQueryResult.isNoData(error)
    }

    func dailyFeedbackHealth(from startDate: Date, through endDate: Date,
                             requireAccessibleData: Bool = false) async throws -> [DailyHealthDay] {
        guard available else { return [] }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)),
              start < end else { return [] }
        func values(_ points: [HealthMeasurePoint]) -> [String: Double] {
            Dictionary(points.map { (FoodDates.localDate(for: $0.date), $0.value) },
                       uniquingKeysWith: { _, latest in latest })
        }
        func read(_ enabled: Bool, query: () async throws -> [HealthMeasurePoint]) async throws -> [String: Double] {
            try Task.checkCancellation()
            guard enabled else { return [:] }
            do {
                let result = try await query()
                try Task.checkCancellation()
                return values(result)
            } catch {
                try Task.checkCancellation()
                if requireAccessibleData && !Self.isNoData(error) { throw error }
                return [:]
            }
        }
        let active = try await read(requested) {
            try await dailyCumulativeEnergy(of: energy, from: start, to: end)
        }
        let resting = try await read(restingRequested) {
            try await dailyCumulativeEnergy(of: restingEnergy, from: start, to: end)
        }
        let waterValues = try await read(waterRequested) {
            try await dailyCumulative(of: water, from: start, to: end, unit: .literUnit(with: .milli))
        }
        let weights = try await read(weightRequested) {
            try await dailyHistory(of: bodyMass, from: start, to: end, unit: .gramUnit(with: .kilo), scale: 1)
        }
        let fat = try await read(bodyFatRequested) {
            try await dailyHistory(of: bodyFat, from: start, to: end, unit: .percent(), scale: 100)
        }
        try Task.checkCancellation()
        let dayCount = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        return (0..<dayCount).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let key = FoodDates.localDate(for: date)
            return DailyHealthDay(localDate: key,
                                  activeKcal: active[key].map { max(0, Int($0.rounded())) },
                                  restingKcal: resting[key].map { max(0, Int($0.rounded())) },
                                  waterMl: waterValues[key].map { max(0, Int($0.rounded())) },
                                  weightKg: weights[key], bodyFatPercent: fat[key])
        }
    }

    func logWaterCup() async {
        guard available, !waterSaving else { return }
        waterSaving = true
        defer { waterSaving = false }
        do {
            if store.authorizationStatus(for: water) != .sharingAuthorized || !waterRequested {
                try await store.requestAuthorization(toShare: [water], read: [water])
                waterRequested = true
                UserDefaults.standard.set(true, forKey: "healthWaterRequested")
            }
            guard store.authorizationStatus(for: water) == .sharingAuthorized else {
                waterErrorMessage = "Allow 00Food to write Water in iPhone Settings → Health → Data Access & Devices."
                return
            }
            let now = Date()
            let sample = HKQuantitySample(type: water,
                quantity: HKQuantity(unit: .literUnit(with: .milli), doubleValue: 250),
                start: now, end: now)
            try await store.save(sample)
            await refreshWater()
        } catch { waterErrorMessage = error.localizedDescription }
    }

    func logWeight(_ kg: Double) async throws {
        guard available else { throw FoodServiceError(message: "Apple Health is not available on this device") }
        guard kg.isFinite && (25...400).contains(kg) else {
            throw FoodServiceError(message: "Enter a weight between 25 and 400 kg")
        }
        try await store.requestAuthorization(toShare: [bodyMass], read: [bodyMass])
        guard store.authorizationStatus(for: bodyMass) == .sharingAuthorized else {
            throw FoodServiceError(message: "Allow 00Food to write Weight in iPhone Settings → Health → Data Access & Devices.")
        }
        let now = Date()
        let sample = HKQuantitySample(type: bodyMass,
            quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kg),
            start: now, end: now)
        try await store.save(sample)
        weightRequested = true
        UserDefaults.standard.set(true, forKey: "healthWeightRequested")
        try await refreshWeight()
    }

    func enableDietaryExport(accountId: String, logs: [FoodLog]) async {
        guard available else {
            dietaryErrorMessage = "Apple Health is not available on this device."
            return
        }
        do {
            try await store.requestAuthorization(toShare: [dietaryEnergy], read: [dietaryEnergy])
            guard dietaryExportAuthorized else {
                dietaryErrorMessage = "Allow 00Food to write Dietary Energy in iPhone Settings → Health → Data Access & Devices."
                return
            }
            if Self.loadDietaryState(for: accountId) == nil {
                Self.saveDietaryState(DietaryExportState(enabledAt: Date()), for: accountId)
            }
            configureDietaryExport(accountId: accountId)
            dietaryExportEnabled = true
            dietaryErrorMessage = nil
            await syncDietaryEnergy(logs: logs, accountId: accountId)
        } catch { dietaryErrorMessage = error.localizedDescription }
    }

    func syncDietaryEnergy(logs: [FoodLog], accountId: String) async {
        guard dietaryExportAuthorized,
              Self.loadDietaryState(for: accountId) != nil else { return }
        if dietarySyncing {
            queuedDietaryLogs = logs
            return
        }
        dietarySyncing = true
        var currentLogs = logs
        repeat {
            queuedDietaryLogs = nil
            do {
                try await reconcileDietaryEnergy(logs: currentLogs, accountId: accountId)
                dietaryErrorMessage = nil
            } catch { dietaryErrorMessage = "Could not update Apple Health: \(error.localizedDescription)" }
            if let queuedDietaryLogs { currentLogs = queuedDietaryLogs }
        } while queuedDietaryLogs != nil && dietaryAccountId == accountId
        dietarySyncing = false
    }

    private func reconcileDietaryEnergy(logs: [FoodLog], accountId: String) async throws {
        guard var state = Self.loadDietaryState(for: accountId) else { return }
        let currentIds = Set(logs.map(\.id))
        let today = Calendar.current.startOfDay(for: Date())
        let oldestSnapshotDay = Calendar.current.date(byAdding: .day, value: -90, to: today) ?? today
        let oldestKey = FoodDates.localDate(for: oldestSnapshotDay)
        for (id, day) in Array(state.exported) where !currentIds.contains(id) {
            if day >= oldestKey {
                let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier,
                    operatorType: .equalTo, value: Self.dietarySyncId(accountId: accountId, logId: id))
                _ = try await store.deleteObjects(of: dietaryEnergy, predicate: predicate)
            }
            state.exported.removeValue(forKey: id)
            Self.saveDietaryState(state, for: accountId)
        }
        for log in logs where state.exported[log.id] == nil {
            guard let loggedAt = FoodDates.parseTimestamp(log.loggedAt), loggedAt >= state.enabledAt,
                  log.kcal > 0 else { continue }
            let syncId = Self.dietarySyncId(accountId: accountId, logId: log.id)
            if try await hasDietarySample(syncId: syncId) == false {
                let sample = HKQuantitySample(type: dietaryEnergy,
                    quantity: HKQuantity(unit: .kilocalorie(), doubleValue: Double(log.kcal)),
                    start: loggedAt, end: loggedAt,
                    metadata: [HKMetadataKeySyncIdentifier: syncId,
                               HKMetadataKeySyncVersion: 1,
                               HKMetadataKeyFoodType: log.foodName])
                try await store.save(sample)
            }
            state.exported[log.id] = log.localDate
            Self.saveDietaryState(state, for: accountId)
        }
    }

    private func hasDietarySample(syncId: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier,
                operatorType: .equalTo, value: syncId)
            let query = HKSampleQuery(sampleType: dietaryEnergy, predicate: predicate, limit: 1,
                                      sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: !(samples ?? []).isEmpty) }
            }
            store.execute(query)
        }
    }

    private static func dietarySyncId(accountId: String, logId: String) -> String {
        "00food.\(accountId).\(logId)"
    }

    private static func dietaryKey(for accountId: String) -> String { "dietaryExport.\(accountId)" }

    private static func loadDietaryState(for accountId: String) -> DietaryExportState? {
        guard let data = UserDefaults.standard.data(forKey: dietaryKey(for: accountId)) else { return nil }
        return try? JSONDecoder().decode(DietaryExportState.self, from: data)
    }

    static func forgetDietaryExport(for accountId: String) {
        UserDefaults.standard.removeObject(forKey: dietaryKey(for: accountId))
    }

    private static func saveDietaryState(_ state: DietaryExportState, for accountId: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: dietaryKey(for: accountId))
    }

    private func dailyCumulativeEnergy(of type: HKQuantityType, from start: Date,
                                       to end: Date) async throws -> [HealthMeasurePoint] {
        try await dailyCumulative(of: type, from: start, to: end, unit: .kilocalorie())
    }

    private func dailyCumulative(of type: HKQuantityType, from start: Date,
                                 to end: Date, unit: HKUnit) async throws -> [HealthMeasurePoint] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HealthMeasurePoint], Error>) in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
            let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                                                    options: .cumulativeSum, anchorDate: start,
                                                    intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, error in
                if let error { continuation.resume(throwing: error) }
                else {
                    let points = collection?.statistics().compactMap { day -> HealthMeasurePoint? in
                        guard let quantity = day.sumQuantity() else { return nil }
                        return HealthMeasurePoint(date: day.startDate,
                                                  value: quantity.doubleValue(for: unit))
                    } ?? []
                    continuation.resume(returning: points)
                }
            }
            store.execute(query)
        }
    }

    private func newestSample(of type: HKQuantityType) async throws -> HKQuantitySample? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HKQuantitySample?, Error>) in
            let newestFirst = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1,
                                      sortDescriptors: [newestFirst]) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples?.first as? HKQuantitySample) }
            }
            store.execute(query)
        }
    }

    private func dailyActiveEnergy(from start: Date) async throws -> [HealthMeasurePoint] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HealthMeasurePoint], Error>) in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: [.strictStartDate])
            let query = HKStatisticsCollectionQuery(quantityType: energy, quantitySamplePredicate: predicate,
                                                    options: .cumulativeSum, anchorDate: start,
                                                    intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, error in
                if let error { continuation.resume(throwing: error) }
                else {
                    let points = collection?.statistics().compactMap { day -> HealthMeasurePoint? in
                        guard let quantity = day.sumQuantity() else { return nil }
                        return HealthMeasurePoint(date: day.startDate,
                                                  value: quantity.doubleValue(for: .kilocalorie()))
                    } ?? []
                    continuation.resume(returning: points)
                }
            }
            store.execute(query)
        }
    }

    private func dailyHistory(of type: HKQuantityType, from start: Date, to end: Date = Date(),
                              unit: HKUnit, scale: Double) async throws -> [HealthMeasurePoint] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HealthMeasurePoint], Error>) in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
            let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                                                    options: .discreteAverage, anchorDate: start,
                                                    intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, error in
                if let error { continuation.resume(throwing: error) }
                else {
                    let points = collection?.statistics().compactMap { day -> HealthMeasurePoint? in
                        guard let quantity = day.averageQuantity() else { return nil }
                        return HealthMeasurePoint(date: day.startDate,
                                                  value: quantity.doubleValue(for: unit) * scale)
                    } ?? []
                    continuation.resume(returning: points)
                }
            }
            store.execute(query)
        }
    }
}
