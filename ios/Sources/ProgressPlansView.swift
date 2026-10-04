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
                    Text("A fixed calorie gap does not produce a fixed rate of weight loss. Your body adapts, and daily weight and body-fat measurements vary. Use the charts to compare directions, then adjust from your recorded trend.")
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
        let projection = projectedWeight(from: health.weightHistory.last?.value ?? profile.weightKg, gap: gap)
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
            Text("Illustrative 8-week change: about \((Double(gap * 56) / 7700).formatted(.number.precision(.fractionLength(1)))) kg")
                .font(.footnote).foregroundStyle(.secondary)
            if health.weightHistory.isEmpty {
                Text("No Health weight readings since you joined. The dashed line starts from your saved weight.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Chart {
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
            HStack(spacing: 14) {
                Label("Health weight", systemImage: "circle.fill").foregroundStyle(.blue)
                Label("Illustration", systemImage: "circle.dotted").foregroundStyle(.orange)
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
            if health.bodyFatHistory.isEmpty {
                Text("No body-fat readings are available for this period.")
                    .foregroundStyle(.secondary)
            } else {
                Chart(health.bodyFatHistory) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Body fat", point.value))
                        .foregroundStyle(.teal)
                    PointMark(x: .value("Date", point.date), y: .value("Body fat", point.value))
                        .foregroundStyle(.teal)
                }
                .frame(height: 180)
                .chartYAxisLabel("%")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func projectedWeight(from weight: Double, gap: Int) -> [HealthMeasurePoint] {
        let today = Calendar.current.startOfDay(for: Date())
        return (0...8).compactMap { week in
            guard let date = Calendar.current.date(byAdding: .day, value: week * 7, to: today) else { return nil }
            return HealthMeasurePoint(date: date, value: max(25, weight - Double(gap * week * 7) / 7700))
        }
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
