import Foundation
import HealthKit
import Observation

struct HealthMeasurePoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

@MainActor @Observable final class HealthEnergy {
    var activeKcal = 0
    var latestWeightKg: Double?
    var latestWeightDate: Date?
    var latestBodyFatPercent: Double?
    var latestBodyFatDate: Date?
    var weightHistory: [HealthMeasurePoint] = []
    var bodyFatHistory: [HealthMeasurePoint] = []
    var requested = UserDefaults.standard.bool(forKey: "healthRequested")
    var weightRequested = UserDefaults.standard.bool(forKey: "healthWeightRequested")
    var bodyFatRequested = UserDefaults.standard.bool(forKey: "healthBodyFatRequested")
    var errorMessage: String?
    private var historyStart: Date?
    private let store = HKHealthStore()
    private let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!
    private let bodyMass = HKObjectType.quantityType(forIdentifier: .bodyMass)!
    private let bodyFat = HKObjectType.quantityType(forIdentifier: .bodyFatPercentage)!

    var available: Bool { HKHealthStore.isHealthDataAvailable() }

    func setHistoryStart(_ date: Date?) {
        let start = date.map { Calendar.current.startOfDay(for: $0) }
        if historyStart != start {
            historyStart = start
            weightHistory = []
            bodyFatHistory = []
        }
    }

    func connect() async {
        guard available else {
            errorMessage = "Apple Health is not available on this device."
            return
        }
        do {
            try await store.requestAuthorization(toShare: [], read: [energy, bodyMass, bodyFat])
            requested = true
            weightRequested = true
            bodyFatRequested = true
            UserDefaults.standard.set(true, forKey: "healthRequested")
            UserDefaults.standard.set(true, forKey: "healthWeightRequested")
            UserDefaults.standard.set(true, forKey: "healthBodyFatRequested")
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func refresh() async {
        guard requested && available else { return }
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
