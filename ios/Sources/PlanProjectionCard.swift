import Charts
import SwiftUI

// The same projection renders the saved plan and the unsaved pace preview.
struct PlanProjectionCard: View {
    let profile: FoodProfile
    let firstDay: Date
    var onChangePlan: (() -> Void)? = nil
    @Environment(HealthEnergy.self) private var health

    private static func spokenDay(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .omitted) }
    private static func spokenKg(_ kg: Double) -> String { "\(kg.formatted(.number.precision(.fractionLength(1)))) kilograms" }
    private static func isMonthStart(_ date: Date) -> Bool { Calendar.current.component(.day, from: date) == 1 }

    var body: some View {
        let deficit = profile.deficitPercent
        let title = DeficitLevel(rawValue: deficit)?.title ?? "Custom"
        let budget = health.representativeBudget(for: profile, deficitPercent: deficit)
        let gap = budget.gapKcal
        let expenditureExplanation = health.completedAverageTDEEKcal != nil
            ? "This illustration uses \(budget.tdeeKcal) kcal/day TDEE, averaged across \(health.completedTDEEDaysUsed) paired resting and active Health days from the last seven completed days: a \(gap) kcal/day gap."
            : "Until paired completed Health days are available, this illustration uses the \(budget.tdeeKcal) kcal/day resting estimate: a \(gap) kcal/day gap."

        let healthyRange = ProgressProjection.healthyWeightRange(for: profile.heightCm)
        let startingWeight = health.usableLatestWeightKg ?? health.weightHistory.last?.value ?? profile.weightKg
        let today = Calendar.current.startOfDay(for: Date())
        let sixMonths = Calendar.current.date(byAdding: .month, value: 6, to: today) ?? today
        let projection = ProgressProjection.projectedWeight(from: startingWeight, gap: gap,
                                         minimum: healthyRange.lowerBound, until: sixMonths)
        let bmiEntryDate = ProgressProjection.estimatedBMIEntryDate(from: startingWeight, gap: gap,
                                                 upperBound: healthyRange.upperBound, until: sixMonths)
        let fullProjection = projection.last?.date == sixMonths
        let chartTop = max(healthyRange.upperBound, profile.weightKg,
                           health.weightHistory.map(\.value).max() ?? 0,
                           projection.map(\.value).max() ?? 0) + 4
        let shownChange = (projection.first?.value ?? 0) - (projection.last?.value ?? 0)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.title3.bold())
                InfoDisclosure(title: "About these charts", message: "Dotted lines are illustrations, not predictions.\n\nBMI is an adult screening measure, not a personal diagnosis or target. Your daily allowance is TDEE × (1 − your deficit percentage), including exercise. Today uses the seven-day resting estimate plus active energy so far. For the illustration we hold recent completed-day TDEE constant; expenditure and the calorie gap will change as your activity and body change. Your body adapts, and daily weight and body-fat measurements vary. Use the charts to compare directions, then adjust from your recorded trend.\n\n" + expenditureExplanation)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(deficit)% deficit").font(.subheadline.bold())
                }
            }
            Text("Today’s allowance \(profile.budget(resting: health.effectiveRestingKcal(for: profile), active: health.activeKcal, deficitPercent: deficit).allowanceKcal) kcal · \(100 - deficit)% of TDEE")
                .font(.subheadline).foregroundStyle(.secondary)
            if projection.count > 1 {
                Text("Illustrative \(fullProjection ? "6-month" : "shown") change: about \(shownChange.formatted(.number.precision(.fractionLength(1)))) kg")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("Adult BMI 18.5–24.9 at your height: \(healthyRange.lowerBound.formatted(.number.precision(.fractionLength(1))))–\(healthyRange.upperBound.formatted(.number.precision(.fractionLength(1)))) kg")
                .font(.footnote).foregroundStyle(.secondary)
            if health.weightHistory.isEmpty {
                Text("No weight readings since you joined. The dotted line starts from your latest recorded weight, or your saved weight if unavailable.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !fullProjection {
                Text("The illustration stops at the BMI 18.5 chart floor.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if health.weightHistory.contains(where: { $0.value < healthyRange.lowerBound }) {
                Text("Recorded weights below the chart floor are not shown here.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Chart {
                RectangleMark(xStart: .value("Account start", firstDay),
                              xEnd: .value("Six months", sixMonths),
                              yStart: .value("Healthy BMI minimum", healthyRange.lowerBound),
                              yEnd: .value("Healthy BMI maximum", healthyRange.upperBound))
                    .foregroundStyle(.green.opacity(0.12))
                    .accessibilityLabel("Healthy BMI range")
                    .accessibilityValue("\(Self.spokenKg(healthyRange.lowerBound)) to \(Self.spokenKg(healthyRange.upperBound))")
                ForEach(health.weightHistory) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Recorded weight", point.value),
                             series: .value("Series", "Weight"))
                        .foregroundStyle(.blue)
                        .accessibilityHidden(true)
                    PointMark(x: .value("Date", point.date), y: .value("Recorded weight", point.value))
                        .foregroundStyle(.blue)
                        .accessibilityLabel(Self.spokenDay(point.date))
                        .accessibilityValue("Recorded \(Self.spokenKg(point.value))")
                }
                ForEach(projection) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Illustration", point.value),
                             series: .value("Series", "Projected weight"))
                        .foregroundStyle(.blue)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [2, 4]))
                        .accessibilityLabel(Self.spokenDay(point.date))
                        .accessibilityValue("Illustration \(Self.spokenKg(point.value))")
                        .accessibilityHidden(!Self.isMonthStart(point.date))
                }
            }
            .frame(height: 170)
            .chartLegend(.hidden)
            .chartYScale(domain: healthyRange.lowerBound...chartTop)
            .chartXAxis {
                AxisMarks(values: .stride(by: .month, count: 1)) {
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .stride(by: 5.0)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let kg = value.as(Double.self) { Text("\(Int(kg))") }
                    }
                }
            }
            HStack(spacing: 14) {
                Label("Weight", systemImage: "circle.fill").labelStyle(.tintedIcon(.blue))
                Label("Illustration", systemImage: "circle.dotted").labelStyle(.tintedIcon(.blue))
                Label("BMI range", systemImage: "rectangle.fill").labelStyle(.tintedIcon(.green))
            }
            .font(.caption).foregroundStyle(.secondary)
            if let bmiEntryDate {
                Text("Estimated entry into the BMI range: \(bmiEntryDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.subheadline.weight(.medium))
            }
            if let onChangePlan {
                Button("Change plan", action: onChangePlan)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

}
