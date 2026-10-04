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
    private var aceThreshold: Double? {
        switch profile?.estimateProfile {
        case "male": 25
        case "female": 32
        default: nil
        }
    }
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
        let startingWeight = health.weightHistory.last?.value ?? profile.weightKg
        let today = Calendar.current.startOfDay(for: Date())
        let sixMonths = Calendar.current.date(byAdding: .month, value: 6, to: today) ?? today
        let projection = projectedWeight(from: startingWeight, gap: gap,
                                         minimum: healthyRange.lowerBound, until: sixMonths)
        let bmiEntryDate = estimatedBMIEntryDate(from: startingWeight, gap: gap,
                                                 upperBound: healthyRange.upperBound, until: sixMonths)
        let fullProjection = projection.last?.date == sixMonths
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
                Text("Illustrative \(fullProjection ? "6-month" : "shown") change: about \(shownChange.formatted(.number.precision(.fractionLength(1)))) kg")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("Adult BMI 18.5–24.9 at your height: \(healthyRange.lowerBound.formatted(.number.precision(.fractionLength(1))))–\(healthyRange.upperBound.formatted(.number.precision(.fractionLength(1)))) kg")
                .font(.footnote).foregroundStyle(.secondary)
            if health.weightHistory.isEmpty {
                Text("No Health weight readings since you joined. The dashed line starts from your saved weight.")
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
            if let bmiEntryDate {
                Text("Estimated entry into the adult BMI range: \(bmiEntryDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.subheadline.weight(.medium))
            }
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
                if let aceThreshold {
                    RuleMark(y: .value("ACE classification", aceThreshold))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("ACE \(Int(aceThreshold))%")
                                .font(.caption2).foregroundStyle(.orange)
                        }
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
            if let aceThreshold {
                Text("ACE’s \(profile?.estimateProfile == "female" ? "female" : "male") body-fat classification places its obesity boundary at \(Int(aceThreshold))%.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Choose Female or Male in Your details to show the corresponding ACE classification boundary.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var bodyFatChartRange: ClosedRange<Double> {
        let values = health.bodyFatHistory.map(\.value)
        let marker = aceThreshold ?? 25
        return max(0, min(values.min() ?? marker, marker) - 5)...(max(values.max() ?? marker, marker) + 5)
    }

    private func projectedWeight(from weight: Double, gap: Int, minimum: Double, until end: Date) -> [HealthMeasurePoint] {
        let today = Calendar.current.startOfDay(for: Date())
        let totalDays = max(0, Calendar.current.dateComponents([.day], from: today, to: end).day ?? 0)
        var days = Array(stride(from: 0, through: totalDays, by: 7))
        if days.last != totalDays { days.append(totalDays) }
        return days.compactMap { day in
            guard let date = Calendar.current.date(byAdding: .day, value: day, to: today) else { return nil }
            return HealthMeasurePoint(date: date, value: weight - Double(gap * day) / 7700)
        }.prefix { $0.value >= minimum }
         .map { $0 }
    }

    private func estimatedBMIEntryDate(from weight: Double, gap: Int,
                                       upperBound: Double, until end: Date) -> Date? {
        guard weight > upperBound, gap > 0 else { return nil }
        let today = Calendar.current.startOfDay(for: Date())
        let daysToEntry = Int(ceil((weight - upperBound) * 7700 / Double(gap)))
        guard let entry = Calendar.current.date(byAdding: .day, value: daysToEntry, to: today),
              entry <= end else { return nil }
        return entry
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
