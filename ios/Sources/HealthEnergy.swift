import Foundation
import HealthKit
import Observation

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
    var latestHeightCm: Double?
    var healthEstimateProfile: String?
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
    var profileDetailsRequested = UserDefaults.standard.bool(forKey: "healthProfileDetailsRequested")
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
    private var readingDay = HealthDaySnapshot.Day()
    private let dayCache: HealthDayCache
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
    private let height = HKObjectType.quantityType(forIdentifier: .height)!
    private let biologicalSex = HKObjectType.characteristicType(forIdentifier: .biologicalSex)!

    var available: Bool { HKHealthStore.isHealthDataAvailable() }
    var isRefreshingWater: Bool { waterRefreshCount > 0 }
    var allowanceIsReady: Bool { !available || !requested || (hasLoadedAllowance && readingDay == HealthDaySnapshot.Day()) }
    var dietaryExportAuthorized: Bool {
        available && store.authorizationStatus(for: dietaryEnergy) == .sharingAuthorized
    }

    init(dayCache: HealthDayCache = HealthDayCache()) {
        self.dayCache = dayCache
        if let snapshot = dayCache.load() {
            if let allowance = snapshot.allowance {
                activeKcal = allowance.activeKcal
                restingAverageKcal = allowance.restingAverageKcal
                restingDaysUsed = allowance.restingDaysUsed
                hasLoadedAllowance = true
            }
            waterMlToday = snapshot.waterMl ?? 0
            latestWeightKg = snapshot.weightKg
            latestWeightDate = snapshot.weightDate
            latestBodyFatPercent = snapshot.bodyFatPercent
            latestBodyFatDate = snapshot.bodyFatDate
        }
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
        try await store.requestAuthorization(toShare: [], read: [energy, restingEnergy, bodyMass, bodyFat, water, height, biologicalSex])
        requested = true
        restingRequested = true
        weightRequested = true
        bodyFatRequested = true
        waterRequested = true
        profileDetailsRequested = true
        for key in ["healthRequested", "healthRestingRequested", "healthWeightRequested", "healthBodyFatRequested", "healthWaterRequested", "healthProfileDetailsRequested"] {
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    func refresh() async {
        resetReadingsForNewDay()
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
        resetReadingsForNewDay()
        let requestedDay = readingDay
        guard available else { return }
        if profileDetailsRequested { await refreshProfileDetails() }
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
            let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: start) ?? start
            let restingDays = try await HealthQueryResult.read(noData: [HealthMeasurePoint]()) {
                try await dailyCumulativeEnergy(of: restingEnergy, from: sevenDaysAgo, to: start)
            }.filter { $0.value > 0 && $0.date < start }
            let restingSummary = RestingEnergySummary(completedDayTotals: restingDays.map(\.value))
            var refreshedActiveHistory = activeHistory
            if let historyStart {
                let ninetyDaysAgo = Calendar.current.date(byAdding: .day, value: -89, to: start) ?? start
                refreshedActiveHistory = try await HealthQueryResult.read(noData: [HealthMeasurePoint]()) {
                    try await dailyActiveEnergy(from: max(historyStart, ninetyDaysAgo))
                }
            }

            let weightReadings = weightRequested ? try await readWeight() : nil
            var refreshedFat = latestBodyFatPercent
            var refreshedFatDate = latestBodyFatDate
            var refreshedFatHistory = bodyFatHistory
            if bodyFatRequested {
                let latest = try await HealthQueryResult.read(noData: Optional<HKQuantitySample>.none) {
                    try await newestSample(of: bodyFat)
                }
                refreshedFat = latest.map { $0.quantity.doubleValue(for: .percent()) * 100 }
                refreshedFatDate = latest?.endDate
                if let historyStart {
                    refreshedFatHistory = try await HealthQueryResult.read(noData: [HealthMeasurePoint]()) {
                        try await dailyLastReadings(of: bodyFat, from: historyStart, unit: .percent(), scale: 100)
                    }
                    if let last = refreshedFatHistory.last, last.date >= (refreshedFatDate ?? .distantPast) {
                        refreshedFat = last.value
                        refreshedFatDate = last.date
                    }
                }
            }
            guard requestedDay == HealthDaySnapshot.Day() else { resetReadingsForNewDay(); return }
            // Publish the budget together, so a partial refresh cannot move the
            // pace marker to one allowance and then back to another.
            activeKcal = max(0, Int(active.rounded()))
            restingDaysUsed = restingSummary.daysUsed
            restingAverageKcal = restingSummary.averageKcal
            activeHistory = refreshedActiveHistory
            if let weightReadings { applyWeight(weightReadings) }
            latestBodyFatPercent = refreshedFat
            latestBodyFatDate = refreshedFatDate
            bodyFatHistory = refreshedFatHistory
            errorMessage = nil
            hasLoadedAllowance = true
            cacheReadings(allowance: true, body: true)
        } catch {
            guard requestedDay == HealthDaySnapshot.Day() else { resetReadingsForNewDay(); return }
            temporaryReadFailure = HealthQueryResult.isTemporarilyUnavailable(error)
            errorMessage = error.localizedDescription
        }
        if waterRequested { await refreshWater() }
    }

    private struct WeightReadings {
        let kg: Double?
        let date: Date?
        let history: [HealthMeasurePoint]
    }

    private func readWeight() async throws -> WeightReadings {
        let latest = try await HealthQueryResult.read(noData: Optional<HKQuantitySample>.none) {
            try await newestSample(of: bodyMass)
        }
        var history = weightHistory
        if let historyStart {
            history = try await HealthQueryResult.read(noData: [HealthMeasurePoint]()) {
                try await dailyHistory(of: bodyMass, from: historyStart, unit: .gramUnit(with: .kilo), scale: 1)
            }
        }
        return WeightReadings(kg: latest?.quantity.doubleValue(for: .gramUnit(with: .kilo)),
                              date: latest?.endDate, history: history)
    }

    private func applyWeight(_ readings: WeightReadings) {
        latestWeightKg = readings.kg
        latestWeightDate = readings.date
        weightHistory = readings.history
    }

    private func refreshWeight() async throws {
        resetReadingsForNewDay()
        let requestedDay = readingDay
        let readings = try await readWeight()
        guard requestedDay == HealthDaySnapshot.Day() else { resetReadingsForNewDay(); return }
        applyWeight(readings)
        cacheReadings(body: true)
    }

    private func refreshProfileDetails() async {
        // These optional setup readings must not interrupt the energy budget.
        // A denied/unset value leaves the editable manual fallback available.
        do {
            let sample = try await HealthQueryResult.read(noData: Optional<HKQuantitySample>.none) {
                try await newestSample(of: height)
            }
            let cm = sample?.quantity.doubleValue(for: .meterUnit(with: .centi))
            latestHeightCm = cm.flatMap { $0.isFinite && (100...250).contains($0) ? $0 : nil }
        } catch {
            if !HealthQueryResult.isTemporarilyUnavailable(error) { latestHeightCm = nil }
        }
        do {
            switch try store.biologicalSex().biologicalSex {
            case .female: healthEstimateProfile = "female"
            case .male: healthEstimateProfile = "male"
            case .other: healthEstimateProfile = "neutral"
            case .notSet: healthEstimateProfile = nil
            @unknown default: healthEstimateProfile = nil
            }
        } catch {
            if !HealthQueryResult.isTemporarilyUnavailable(error) { healthEstimateProfile = nil }
        }
    }

    func refreshWater() async {
        resetReadingsForNewDay()
        guard waterRequested && available else { return }
        let requestID = UUID()
        waterRefreshID = requestID
        waterRefreshCount += 1
        defer { waterRefreshCount -= 1 }
        waterErrorMessage = nil
        temporaryWaterReadFailure = false
        let requestedDay = readingDay
        let start = Calendar.current.startOfDay(for: Date())
        do {
            let milliliters = try await waterMilliliters(from: start, to: Date())
            guard waterRefreshID == requestID, requestedDay == HealthDaySnapshot.Day() else { return }
            waterMlToday = milliliters
            waterErrorMessage = nil
            cacheReadings(water: true)
        } catch {
            guard waterRefreshID == requestID, requestedDay == HealthDaySnapshot.Day() else { return }
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

    func resetReadingsForNewDay(on date: Date = Date(), calendar: Calendar = .current) {
        let today = HealthDaySnapshot.Day(date: date, calendar: calendar)
        guard readingDay != today else { return }
        readingDay = today
        waterRefreshID = UUID()
        activeKcal = 0
        restingAverageKcal = nil
        restingDaysUsed = 0
        hasLoadedAllowance = false
        waterMlToday = 0
        latestWeightKg = nil
        latestWeightDate = nil
        latestBodyFatPercent = nil
        latestBodyFatDate = nil
        errorMessage = nil
        waterErrorMessage = nil
    }

    private func cacheReadings(allowance: Bool = false, water: Bool = false, body: Bool = false) {
        guard readingDay == HealthDaySnapshot.Day() else { return }
        var snapshot = dayCache.load() ?? HealthDaySnapshot(day: readingDay)
        if allowance {
            snapshot.allowance = .init(activeKcal: activeKcal, restingAverageKcal: restingAverageKcal,
                                       restingDaysUsed: restingDaysUsed)
        }
        if water { snapshot.waterMl = waterMlToday }
        if body {
            snapshot.weightKg = latestWeightKg
            snapshot.weightDate = latestWeightDate
            snapshot.bodyFatPercent = latestBodyFatPercent
            snapshot.bodyFatDate = latestBodyFatDate
        }
        dayCache.save(snapshot)
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
            try await dailyLastReadings(of: bodyFat, from: start, to: end, unit: .percent(), scale: 100)
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
        resetReadingsForNewDay()
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

    // Watch commands are retried across two durable queues. The sync identifier
    // makes a water write idempotent even if the phone stops before replying.
    func applyWatchWater(id: String, accountId: String, at date: Date, undo: Bool = false) async throws {
        guard available, store.authorizationStatus(for: water) == .sharingAuthorized else {
            throw WatchActionError(message: "Open 00Food on your iPhone and tap a water glass to allow Apple Health water logging.")
        }
        let syncID = "00food.watch.water.\(accountId).\(id)"
        let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier,
                                                   operatorType: .equalTo, value: syncID)
        if undo {
            _ = try await store.deleteObjects(of: water, predicate: predicate)
        } else {
            let exists = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                let query = HKSampleQuery(sampleType: water, predicate: predicate, limit: 1, sortDescriptors: nil) { _, samples, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: !(samples ?? []).isEmpty) }
                }
                store.execute(query)
            }
            if !exists {
                let sample = HKQuantitySample(type: water,
                    quantity: HKQuantity(unit: .literUnit(with: .milli), doubleValue: 250), start: date, end: date,
                    metadata: [HKMetadataKeySyncIdentifier: syncID, HKMetadataKeySyncVersion: 1])
                try await store.save(sample)
            }
        }
        await refreshWater()
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

    private func dailyLastReadings(of type: HKQuantityType, from start: Date, to end: Date = Date(),
                                   unit: HKUnit, scale: Double) async throws -> [HealthMeasurePoint] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HealthMeasurePoint], Error>) in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end,
                                                       options: [.strictStartDate, .strictEndDate])
            let newestFirst = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [newestFirst]) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else {
                    let readings = (samples as? [HKQuantitySample] ?? []).map {
                        HealthMeasurePoint(date: $0.endDate, value: $0.quantity.doubleValue(for: unit) * scale)
                    }
                    continuation.resume(returning: HealthHistory.lastReadingEachDay(readings))
                }
            }
            store.execute(query)
        }
    }
}
