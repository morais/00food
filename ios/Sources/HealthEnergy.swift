import Foundation
import HealthKit
import Observation

@MainActor @Observable final class HealthEnergy {
    var activeKcal = 0
    var requested = UserDefaults.standard.bool(forKey: "healthRequested")
    var errorMessage: String?
    private let store = HKHealthStore()
    private let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!

    var available: Bool { HKHealthStore.isHealthDataAvailable() }

    func connect() async {
        guard available else {
            errorMessage = "Apple Health is not available on this device."
            return
        }
        do {
            try await store.requestAuthorization(toShare: [], read: [energy])
            requested = true
            UserDefaults.standard.set(true, forKey: "healthRequested")
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func refresh() async {
        guard requested && available else { return }
        let start = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date())
        do {
            let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Double, Error>) in
                let query = HKStatisticsQuery(quantityType: energy, quantitySamplePredicate: predicate,
                                              options: .cumulativeSum) { _, statistics, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0) }
                }
                store.execute(query)
            }
            activeKcal = max(0, Int(value.rounded()))
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}
