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
    var errorMessage: String?
    var dietaryExportEnabled = false
    var dietaryErrorMessage: String?
    private var historyStart: Date?
    private var dietaryAccountId: String?
    private var dietarySyncing = false
    private var queuedDietaryLogs: [FoodLog]?
    private let store = HKHealthStore()
    private let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!
    private let restingEnergy = HKObjectType.quantityType(forIdentifier: .basalEnergyBurned)!
    private let dietaryEnergy = HKObjectType.quantityType(forIdentifier: .dietaryEnergyConsumed)!
    private let bodyMass = HKObjectType.quantityType(forIdentifier: .bodyMass)!
    private let bodyFat = HKObjectType.quantityType(forIdentifier: .bodyFatPercentage)!

    var available: Bool { HKHealthStore.isHealthDataAvailable() }
    var dietaryExportAuthorized: Bool {
        available && store.authorizationStatus(for: dietaryEnergy) == .sharingAuthorized
    }

    func effectiveRestingKcal(for profile: FoodProfile) -> Int {
        restingAverageKcal ?? profile.restingKcal
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
            try await store.requestAuthorization(toShare: [], read: [energy, restingEnergy, bodyMass, bodyFat])
            requested = true
            restingRequested = true
            weightRequested = true
            bodyFatRequested = true
            UserDefaults.standard.set(true, forKey: "healthRequested")
            UserDefaults.standard.set(true, forKey: "healthRestingRequested")
            UserDefaults.standard.set(true, forKey: "healthWeightRequested")
            UserDefaults.standard.set(true, forKey: "healthBodyFatRequested")
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func refresh() async {
        guard requested && available else { return }
        if !restingRequested { await connect(); return }
        do {
            let start = Calendar.current.startOfDay(for: Date())
            let today = HKQuery.predicateForSamples(withStart: start, end: Date())
            let active = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Double, Error>) in
                let query = HKStatisticsQuery(quantityType: energy, quantitySamplePredicate: today,
                                              options: .cumulativeSum) { _, statistics, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0) }
                }
                store.execute(query)
            }
            activeKcal = max(0, Int(active.rounded()))
            let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: start) ?? start
            let restingDays = (try? await dailyCumulativeEnergy(of: restingEnergy,
                                                                  from: sevenDaysAgo, to: start))?
                .filter { $0.value > 0 && $0.date < start } ?? []
            let restingSummary = RestingEnergySummary(completedDayTotals: restingDays.map(\.value))
            restingDaysUsed = restingSummary.daysUsed
            restingAverageKcal = restingSummary.averageKcal
            if let historyStart {
                let ninetyDaysAgo = Calendar.current.date(byAdding: .day, value: -89, to: start) ?? start
                activeHistory = try await dailyActiveEnergy(from: max(historyStart, ninetyDaysAgo))
            }

            if weightRequested {
                let latest = try await newestSample(of: bodyMass)
                latestWeightKg = latest?.quantity.doubleValue(for: .gramUnit(with: .kilo))
                latestWeightDate = latest?.endDate
                if let historyStart {
                    weightHistory = try await dailyHistory(of: bodyMass, from: historyStart,
                                                           unit: .gramUnit(with: .kilo), scale: 1)
                }
            }
            if bodyFatRequested {
                let latest = try await newestSample(of: bodyFat)
                latestBodyFatPercent = latest.map { $0.quantity.doubleValue(for: .percent()) * 100 }
                latestBodyFatDate = latest?.endDate
                if let historyStart {
                    bodyFatHistory = try await dailyHistory(of: bodyFat, from: historyStart,
                                                            unit: .percent(), scale: 100)
                }
            }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
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

    private static func saveDietaryState(_ state: DietaryExportState, for accountId: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: dietaryKey(for: accountId))
    }

    private func dailyCumulativeEnergy(of type: HKQuantityType, from start: Date,
                                       to end: Date) async throws -> [HealthMeasurePoint] {
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
                                                  value: quantity.doubleValue(for: .kilocalorie()))
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

    private func dailyHistory(of type: HKQuantityType, from start: Date,
                              unit: HKUnit, scale: Double) async throws -> [HealthMeasurePoint] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HealthMeasurePoint], Error>) in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: [.strictStartDate])
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
