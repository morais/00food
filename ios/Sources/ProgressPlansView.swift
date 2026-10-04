import Charts
import SwiftUI

struct ProgressPlansView: View {
    @Environment(FoodStore.self) private var store
    @Environment(HealthEnergy.self) private var health
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var errorText: String?

    private var profile: FoodProfile? { store.profile }
    private var firstDay: Date { store.accountStartedAt ?? Date() }
    private func healthyWeightRange(for heightCm: Double) -> ClosedRange<Double> {
        let metres = heightCm / 100
        let heightSquared = metres * metres
        return (18.5 * heightSquared)...(24.9 * heightSquared)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Compare three daily calorie gaps. The lines are illustrations, not predictions. Actual weight and body-fat readings come from Apple Health from the day you joined 00Food.")
                        .font(.subheadline).foregroundStyle(.secondary)

                    if !health.bodyFatRequested {
                        Button("Connect Apple Health for weight & body fat") {
                            Task { await health.connect() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if let error = health.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    if let profile {
                        ForEach(DeficitLevel.allCases) { level in
                            planCard(level, profile: profile)
                        }
                    }
                    fatCard
                    Text("BMI is an adult screening measure, not a personal diagnosis or target. A fixed calorie gap does not produce a fixed rate of weight loss. Your body adapts, and daily weight and body-fat measurements vary. Use the charts to compare directions, then adjust from your recorded trend.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .navigationTitle("Progress & plans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task {
                health.setHistoryStart(store.accountStartedAt)
                await health.refresh()
            }
            .refreshable { await health.refresh() }
            .alert("Could not change your plan", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    private func planCard(_ level: DeficitLevel, profile: FoodProfile) -> some View {
        let gap = profile.effectiveDeficit(for: level.rawValue)
        let healthyRange = healthyWeightRange(for: profile.heightCm)
        let projection = projectedWeight(from: health.weightHistory.last?.value ?? profile.weightKg,
                                         gap: gap, minimum: healthyRange.lowerBound)
        let chartTop = max(healthyRange.upperBound, profile.weightKg,
                           health.weightHistory.map(\.value).max() ?? 0,
                           projection.map(\.value).max() ?? 0) + 4
        let shownChange = (projection.first?.value ?? 0) - (projection.last?.value ?? 0)
        let isSelected = profile.deficitKcal == level.rawValue
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(level.title).font(.title3.bold())
                Spacer()
                Text("\(level.rawValue) kcal/day").font(.subheadline.bold())
            }
            Text("Food target \(profile.target(for: level.rawValue)) kcal + Health active energy")
                .font(.subheadline).foregroundStyle(.secondary)
            if gap < level.rawValue {
                Text("The 1,200 kcal floor makes the effective gap about \(gap) kcal/day before activity.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if projection.count > 1 {
                Text("Illustrative \(projection.count == 9 ? "8-week" : "shown") change: about \(shownChange.formatted(.number.precision(.fractionLength(1)))) kg")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("Adult BMI 18.5–24.9 at your height: \(healthyRange.lowerBound.formatted(.number.precision(.fractionLength(1))))–\(healthyRange.upperBound.formatted(.number.precision(.fractionLength(1)))) kg")
                .font(.footnote).foregroundStyle(.secondary)
            if health.weightHistory.isEmpty {
                Text("No Health weight readings since you joined. The dashed line starts from your saved weight.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if projection.count < 9 {
                Text("The illustration stops at the BMI 18.5 chart floor.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if health.weightHistory.contains(where: { $0.value < healthyRange.lowerBound }) {
                Text("Recorded weights below the chart floor are not shown here.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Chart {
                RectangleMark(xStart: .value("Account start", firstDay),
                              xEnd: .value("Eight weeks", Calendar.current.date(byAdding: .day, value: 56, to: Date()) ?? Date()),
                              yStart: .value("Healthy BMI minimum", healthyRange.lowerBound),
                              yEnd: .value("Healthy BMI maximum", healthyRange.upperBound))
                    .foregroundStyle(.green.opacity(0.12))
                ForEach(health.weightHistory) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Recorded weight", point.value))
                        .foregroundStyle(.blue)
                    PointMark(x: .value("Date", point.date), y: .value("Recorded weight", point.value))
                        .foregroundStyle(.blue)
                }
                ForEach(projection) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Illustration", point.value))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                }
            }
            .frame(height: 170)
            .chartLegend(.hidden)
            .chartYScale(domain: healthyRange.lowerBound...chartTop)
            HStack(spacing: 14) {
                Label("Health weight", systemImage: "circle.fill").foregroundStyle(.blue)
                Label("Illustration", systemImage: "circle.dotted").foregroundStyle(.orange)
                Label("BMI range", systemImage: "rectangle.fill").foregroundStyle(.green)
            }
            .font(.caption)
            Button(isSelected ? "Current plan" : "Use this plan") { select(level, profile: profile) }
                .buttonStyle(.borderedProminent)
                .disabled(saving || isSelected)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var fatCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Body fat since you joined").font(.title3.bold())
            Text("From \(firstDay.formatted(date: .abbreviated, time: .omitted)) · Apple Health body-fat percentage")
                .font(.caption).foregroundStyle(.secondary)
            Chart {
                RuleMark(y: .value("25% reference", 25))
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("25% reference").font(.caption2).foregroundStyle(.orange)
                    }
                ForEach(health.bodyFatHistory) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Body fat", point.value))
                        .foregroundStyle(.teal)
                    PointMark(x: .value("Date", point.date), y: .value("Body fat", point.value))
                        .foregroundStyle(.teal)
                }
            }
            .frame(height: 180)
            .chartYAxisLabel("%")
            .chartYScale(domain: bodyFatChartRange)
            if health.bodyFatHistory.isEmpty {
                Text("No body-fat readings are available for this period.")
                    .foregroundStyle(.secondary)
            }
            Text("The 25% line is a reference you requested, not a universal target.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var bodyFatChartRange: ClosedRange<Double> {
        let values = health.bodyFatHistory.map(\.value)
        return max(0, min(values.min() ?? 25, 25) - 5)...(max(values.max() ?? 25, 25) + 5)
    }

    private func projectedWeight(from weight: Double, gap: Int, minimum: Double) -> [HealthMeasurePoint] {
        let today = Calendar.current.startOfDay(for: Date())
        return (0...8).compactMap { week in
            guard let date = Calendar.current.date(byAdding: .day, value: week * 7, to: today) else { return nil }
            return HealthMeasurePoint(date: date, value: weight - Double(gap * week * 7) / 7700)
        }.prefix { $0.value >= minimum }
         .map { $0 }
    }

    private func select(_ level: DeficitLevel, profile: FoodProfile) {
        saving = true
        Task {
            defer { saving = false }
            do {
                var updated = profile
                updated.deficitKcal = level.rawValue
                try await store.saveProfile(updated)
            } catch { errorText = error.localizedDescription }
        }
    }
}
