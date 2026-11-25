import SwiftUI

// Presented only inside Developer settings. No change to public chart labels.
struct ForecastDiagnosticsView: View {
    let profile: FoodProfile
    let calibration: ForecastCalibration
    @Environment(HealthEnergy.self) private var health
    @Environment(FoodStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if let average = CalorieBalanceAverage.lastSevenCompletedDays(in:
                health.calorieHistory(profile: profile, store: store, daysIncludingToday: 8)) {
                Text("Last \(average.dayCount) completed days").fontWeight(.semibold)
                Text(average.label)
                Text("Health TDEE: \(number(average.tdeeKcalPerDay)) kcal/day · Logged food: \(number(average.eatenKcalPerDay)) kcal/day")
                Text("Recorded: \(balance(average.recordedDeficitKcalPerDay, percent: average.tdeeDeficitPercent))")
                Text("These are the same averages and Health fallbacks used in Calories over time. Remaining calories are per day, not the total for the week.")
            }
            if let data = calibration.diagnostics {
                Divider()
                Text("Calibration comparison").fontWeight(.semibold)
                let lastInputDay = Calendar.current.date(byAdding: .day, value: -1, to: data.inputEnd) ?? data.inputEnd
                Text("Input days: \(day(data.inputStart)) – \(day(lastInputDay))")
                Text("Weight fit: \(day(data.fitStart)) – \(day(data.fitEnd))")
                Text(data.usesBodyComposition ? "Energy fit uses paired fat and fat-free mass trends." : "Energy fit uses weight only; recent paired composition data is insufficient.")
                Text("Health TDEE: \(number(data.meanTDEEKcal)) kcal/day · Logged food: \(number(data.meanLoggedKcal)) kcal/day")
                Text("Recorded: \(balance(data.recordedDeficitKcal, percent: data.recordedDeficitPercent))")
                Text("Weight-trend equivalent: \(balance(data.weightEquivalentDeficitKcal, percent: data.weightEquivalentDeficitPercent))")
                let direction = data.rawCorrectionKcal < 0 ? "less" : "more"
                Text("Raw mismatch: \(number(abs(data.rawCorrectionKcal))) kcal/day \(direction) deficit · \(number(abs(data.mismatchPercentagePoints), decimals: 1)) percentage points")
                Text("After cap: \(number(abs(data.limitedCorrectionKcal))) kcal/day \(direction) deficit · Influence: \(number(data.influence * 100, decimals: 1))%")
                Text("Both percentages in this comparison use the same Health TDEE reference and the same weight-fit period. Any missing days use the calibration’s mean-filled values. The weight-trend equivalent is inferred by the model; it is not measured calorie burn. The raw mismatch is capped and damped before becoming the forecast adjustment.")
            }
            Text("Calibration compares Health energy minus actual logged food with the weight trend, not just your selected deficit. The plan forecast then assumes you eat the selected allowance; it does not assume you keep leaving the recent unused calories. These diagnostics cannot separate food-estimation error, Watch error, water changes or model error.")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func balance(_ kcal: Double, percent: Double) -> String {
        let direction = kcal < 0 ? "surplus" : "deficit"
        return "\(number(abs(kcal))) kcal/day \(direction) · \(number(abs(percent), decimals: 1))% of Health TDEE"
    }

    private func number(_ value: Double, decimals: Int = 0) -> String {
        value.formatted(.number.precision(.fractionLength(decimals)))
    }

    private func day(_ date: Date) -> String { date.formatted(.dateTime.day().month(.abbreviated)) }
}
