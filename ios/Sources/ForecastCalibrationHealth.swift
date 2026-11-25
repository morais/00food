import Foundation

@MainActor extension HealthEnergy {
    func forecastCalibration(using store: FoodStore) -> ForecastCalibration? {
        forecastAssessment(using: store)?.calibration
    }

    func forecastAssessment(using store: FoodStore) -> ForecastCalibrationAssessment? {
        guard let start = store.accountStartedAt else { return nil }
        return ForecastCalibration.assess(weights: weightsForForecastCalibration, resting: restingHistory,
                                        active: activeHistory, logs: store.logs, since: start,
                                        composition: compositionTrend)
    }

    func gapForForecast(profile: FoodProfile, store: FoodStore, calibrationEnabled: Bool) -> Int {
        let nominal = representativeBudget(for: profile).gapKcal
        guard calibrationEnabled, let calibration = forecastCalibration(using: store) else { return nominal }
        return calibration.projectionGap(nominal)
    }
}
