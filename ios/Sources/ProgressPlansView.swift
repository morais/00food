import Charts
import SwiftUI

private struct DailyCalorieBalance: Identifiable {
    var date: Date
    var eaten: Int
    var allowance: Int
    var id: Date { date }
}

struct ProgressPlansView: View {
    @Environment(FoodStore.self) private var store

    // VoiceOver wording for chart marks. Projections are daily, so only the
    // first of each month is exposed to keep the chart navigable.
    private static func spokenDay(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .omitted) }
    private static func spokenKg(_ kg: Double) -> String { "\(kg.formatted(.number.precision(.fractionLength(1)))) kilograms" }
    private static func spokenPercent(_ value: Double) -> String { "\(value.formatted(.number.precision(.fractionLength(1)))) percent" }
    private static func isMonthStart(_ date: Date) -> Bool { Calendar.current.component(.day, from: date) == 1 }
    @Environment(HealthEnergy.self) private var health
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var showingOtherPlans = false
    @State private var calorieHistoryDays = 30
    @State private var errorText: String?

    private var profile: FoodProfile? { store.profile }
    private var firstDay: Date { store.accountStartedAt ?? Date() }
    private var aceObesityBoundary: ACEBodyFatBoundary? {
        ProgressProjection.aceBoundaries(for: profile?.estimateProfile ?? "").first
    }
    private var visibleACEBoundaries: [ACEBodyFatBoundary] {
        ProgressProjection.visibleACEBoundaries(for: profile?.estimateProfile ?? "",
                                                projectedPercentages: projectedBodyFat.map(\.value))
    }
    private func aceColor(for boundary: ACEBodyFatBoundary) -> Color {
        switch boundary.category {
        case "Obesity": .orange
        case "Average": .blue
        case "Fitness": .green
        case "Athletes": .purple
        case "Essential": .pink
        default: .gray
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
                    if !health.bodyFatRequested {
                        Button("Connect Apple Health for weight & body fat") {
                            Task { await health.connect() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    DelayedNotice(message: health.errorMessage, isRefreshing: health.isRefreshing) { error in
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    if let profile {
                        let currentLevel = DeficitLevel.allCases.first { $0.rawValue == profile.deficitPercent }
                        planCard(title: currentLevel?.title ?? "Custom", deficit: profile.deficitPercent,
                                 isCurrent: true, profile: profile)
                        DisclosureGroup(isExpanded: $showingOtherPlans) {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(DeficitLevel.allCases.filter { $0.rawValue != profile.deficitPercent }) { level in
                                    planCard(title: level.title, deficit: level.rawValue,
                                             isCurrent: false, profile: profile)
                                }
                            }
                            .padding(.top, 12)
                        } label: {
                            Text("Other plans").font(.headline)
                        }
                        calorieHistoryCard(profile: profile)
                    }
                    fatCard
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

    private func calorieHistoryCard(profile: FoodProfile) -> some View {
        let points = dailyCalorieBalances(profile: profile)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Calories over time").font(.title3.bold())
                Spacer()
                InfoDisclosure(title: "Calories over time", message: "Orange shows logged food within the allowance. Green fills the remaining allowance; red shows food above it. Each bar reaches the allowance or the food total, whichever is higher.\n\nAllowance is (resting + active energy) × (1 − your current plan’s deficit percentage). Completed days use their recorded Health resting and active energy; missing resting energy falls back to the recent resting average or your details estimate, and missing active energy counts as zero. Today uses the resting estimate plus active energy so far. Earlier plan changes are not tracked. Food totals include only food logged in 00Food.")
            }
            Picker("Period", selection: $calorieHistoryDays) {
                Text("30 days").tag(30)
                Text("90 days").tag(90)
            }
            .pickerStyle(.segmented)
            if !points.isEmpty {
                Chart {
                    ForEach(points) { point in
                        BarMark(x: .value("Day", point.date, unit: .day),
                                yStart: .value("Calories", 0),
                                yEnd: .value("Calories", min(point.eaten, point.allowance)))
                            .foregroundStyle(Color.orange.opacity(0.75))
                            .accessibilityLabel(Self.spokenDay(point.date))
                            .accessibilityValue("\(point.eaten) calories logged of \(point.allowance) allowance; \(abs(point.allowance - point.eaten)) \(point.eaten > point.allowance ? "over allowance" : "remaining")")
                        // Explicit ranges keep excess calories part of the food
                        // total rather than adding them above that total again.
                        if point.eaten < point.allowance {
                            BarMark(x: .value("Day", point.date, unit: .day),
                                    yStart: .value("Calories", point.eaten),
                                    yEnd: .value("Calories", point.allowance))
                                .foregroundStyle(Color.green.opacity(0.45))
                                .accessibilityHidden(true)
                        } else if point.eaten > point.allowance {
                            BarMark(x: .value("Day", point.date, unit: .day),
                                    yStart: .value("Calories", point.allowance),
                                    yEnd: .value("Calories", point.eaten))
                                .foregroundStyle(Color.red.opacity(0.85))
                                .accessibilityHidden(true)
                        }
                    }
                }
                .frame(height: 190)
                .chartLegend(.hidden)
                .chartXScale(domain: calorieHistoryDomain)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                          alignment: .leading, spacing: 8) {
                    Label("Logged food", systemImage: "square.fill").labelStyle(.tintedIcon(.orange))
                    Label("Remaining", systemImage: "square.fill").labelStyle(.tintedIcon(.green))
                    Label("Over allowance", systemImage: "square.fill").labelStyle(.tintedIcon(.red))
                }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No calorie history yet.").foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var calorieHistoryDomain: ClosedRange<Date> {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: 1 - calorieHistoryDays, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        return start...end
    }

    private func dailyCalorieBalances(profile: FoodProfile) -> [DailyCalorieBalance] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let windowStart = calendar.date(byAdding: .day, value: 1 - calorieHistoryDays, to: today) ?? today
        let accountStart = calendar.startOfDay(for: store.accountStartedAt ?? today)
        let first = max(windowStart, accountStart)
        guard first <= today else { return [] }
        var foodByDay: [String: Int] = [:]
        for log in store.logs { foodByDay[log.localDate, default: 0] += log.kcal }
        var days: [DailyCalorieBalance] = []
        var date = first
        while date <= today {
            let key = FoodDates.localDate(for: date)
            days.append(DailyCalorieBalance(date: date, eaten: foodByDay[key] ?? 0,
                                            allowance: health.budget(for: profile, on: date).allowanceKcal))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        return days
    }

    private func planCard(title: String, deficit: Int, isCurrent: Bool, profile: FoodProfile) -> some View {
        let budget = health.representativeBudget(for: profile, deficitPercent: deficit)
        let gap = budget.gapKcal
        let expenditureExplanation = health.completedAverageTDEEKcal != nil
            ? "This illustration uses \(budget.tdeeKcal) kcal/day TDEE, averaged across \(health.completedTDEEDaysUsed) paired resting and active Health days from the last seven completed days: a \(gap) kcal/day gap."
            : "Until paired completed Health days are available, this illustration uses the \(budget.tdeeKcal) kcal/day resting estimate: a \(gap) kcal/day gap."

        let healthyRange = healthyWeightRange(for: profile.heightCm)
        let startingWeight = health.usableLatestWeightKg ?? health.weightHistory.last?.value ?? profile.weightKg
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
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.title3.bold())
                InfoDisclosure(title: "About these charts", message: "Dotted lines are illustrations, not predictions.\n\nBMI is an adult screening measure, not a personal diagnosis or target. Your daily allowance is TDEE × (1 − your deficit percentage), including exercise. Today uses the seven-day resting estimate plus active energy so far. For the illustration we hold recent completed-day TDEE constant; expenditure and the calorie gap will change as your activity and body change. Your body adapts, and daily weight and body-fat measurements vary. Use the charts to compare directions, then adjust from your recorded trend.\n\n" + expenditureExplanation)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if isCurrent { Text("Current plan").font(.caption).foregroundStyle(.tint) }
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
            if !isCurrent {
                Button("Use this plan") { select(deficit, profile: profile) }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var fatCard: some View {
        let projection = projectedBodyFat
        let today = Calendar.current.startOfDay(for: Date())
        let sixMonths = Calendar.current.date(byAdding: .month, value: 6, to: today) ?? today
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Body fat over time").font(.title3.bold())
                Spacer()
                InfoDisclosure(title: "Body fat over time", message: bodyFatExplanation,
                    linkTitle: aceObesityBoundary == nil ? nil : "ACE body-fat category chart",
                    linkURL: aceObesityBoundary == nil ? nil : URL(string: "https://www.acefitness.org/fitness-certifications/ace-answers/exam-preparation-blog/3815/anthropometric-measurements-when-to-use-this-assessment/"))
            }
            Chart {
                ForEach(visibleACEBoundaries) { boundary in
                    RuleMark(y: .value("ACE category boundary", boundary.percentage))
                        .foregroundStyle(aceColor(for: boundary))
                        .lineStyle(StrokeStyle(lineWidth: boundary.isObesity ? 1.5 : 1, dash: [5, 4]))
                        .accessibilityLabel("ACE \(boundary.category) boundary")
                        .accessibilityValue("\(Int(boundary.percentage)) percent")
                }
                ForEach(health.bodyFatHistory) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Body fat", point.value),
                             series: .value("Series", "Body fat"))
                        .foregroundStyle(.teal)
                        .accessibilityHidden(true)
                    PointMark(x: .value("Date", point.date), y: .value("Body fat", point.value))
                        .foregroundStyle(.teal)
                        .accessibilityLabel(Self.spokenDay(point.date))
                        .accessibilityValue("Recorded \(Self.spokenPercent(point.value)) body fat")
                }
                ForEach(projection) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Illustrated body fat", point.value),
                             series: .value("Series", "Projected body fat"))
                        .foregroundStyle(.teal)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [2, 4]))
                        .accessibilityLabel(Self.spokenDay(point.date))
                        .accessibilityValue("Illustration \(Self.spokenPercent(point.value)) body fat")
                        .accessibilityHidden(!Self.isMonthStart(point.date))
                }
            }
            .frame(height: 180)
            .chartYAxisLabel("%")
            .chartYScale(domain: bodyFatChartRange)
            .chartXScale(domain: firstDay...sixMonths)
            .chartXAxis {
                AxisMarks(values: .stride(by: .month, count: 1)) {
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
            HStack(spacing: 14) {
                Label("Body fat", systemImage: "circle.fill").labelStyle(.tintedIcon(.teal))
                Label("Illustration", systemImage: "circle.dotted").labelStyle(.tintedIcon(.teal))
            }
            .font(.caption).foregroundStyle(.secondary)
            if !visibleACEBoundaries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(visibleACEBoundaries) { boundary in
                        HStack(alignment: .top, spacing: 7) {
                            Capsule()
                                .fill(aceColor(for: boundary))
                                .frame(width: 18, height: 2)
                                .padding(.top, 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("ACE \(boundary.category) · \(Int(boundary.percentage))%")
                                Text(aceForecastLabel(for: boundary, projection: projection))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var bodyFatExplanation: String {
        var paragraphs: [String] = []
        if health.bodyFatHistory.isEmpty {
            paragraphs.append("No body-fat readings since you joined. An illustration, if shown, starts from your latest Health reading.")
        }
        if projectedBodyFat.isEmpty {
            paragraphs.append("Add a body-fat reading in Apple Health to show an illustration.")
        } else {
            paragraphs.append("Each day shows its last recorded body-fat reading. The dotted line starts at the latest plotted reading, using the available weight for that date. If no history is available, it uses your latest reading and weight. It applies your plan’s percentage deficit to recent completed-day TDEE (resting + active energy), held constant for the illustration. It assumes every kilogram of illustrated weight loss is fat, with lean mass unchanged. It is a rough illustration, not a prediction.")
        }
        if let aceObesityBoundary {
            paragraphs.append("ACE’s \(profile?.estimateProfile == "female" ? "female" : "male") body-fat classification places its obesity boundary at \(Int(aceObesityBoundary.percentage))%. Other category boundaries appear when the illustration crosses them.")
        } else {
            paragraphs.append("Choose Female or Male in Your details to show the corresponding ACE classification boundary.")
        }
        return paragraphs.joined(separator: "\n\n")
    }

    private func aceForecastLabel(for boundary: ACEBodyFatBoundary,
                                  projection: [HealthMeasurePoint]) -> String {
        guard let first = projection.first else { return "No projection" }
        if first.value <= boundary.percentage { return "Already below" }
        guard let date = ACEThresholdForecast.crossingDate(for: boundary.percentage, in: projection) else {
            return "Not reached in projection"
        }
        return "Estimated \(date.formatted(.dateTime.day().month(.abbreviated).year()))"
    }

    private var bodyFatChartRange: ClosedRange<Double> {
        let values = health.bodyFatHistory.map(\.value) + projectedBodyFat.map(\.value)
        let marker = aceObesityBoundary?.percentage ?? 25
        return max(0, min(values.min() ?? marker, marker) - 5)...(max(values.max() ?? marker, marker) + 5)
    }

    private var projectedBodyFat: [HealthMeasurePoint] {
        guard let profile else { return [] }
        let fallback = health.latestBodyFatPercent.flatMap { value in
            health.latestBodyFatDate.map { HealthMeasurePoint(date: $0, value: value) }
        }
        guard let anchor = ProgressProjection.bodyFatAnchor(history: health.bodyFatHistory, fallback: fallback) else { return [] }
        let anchorDay = Calendar.current.startOfDay(for: anchor.date)
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: anchorDay) ?? anchorDay
        let startingWeight = health.weightHistory.filter { $0.date < nextDay }.max { $0.date < $1.date }?.value
            ?? health.usableLatestWeightKg ?? profile.weightKg
        let today = Calendar.current.startOfDay(for: Date())
        let sixMonths = Calendar.current.date(byAdding: .month, value: 6, to: today) ?? today
        return ProgressProjection.bodyFatProjection(anchor: anchor, startWeightKg: startingWeight,
            gapKcal: health.representativeBudget(for: profile).gapKcal,
            minimumWeightKg: healthyWeightRange(for: profile.heightCm).lowerBound, until: sixMonths)
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

    private func select(_ deficit: Int, profile: FoodProfile) {
        saving = true
        Task {
            defer { saving = false }
            do {
                var updated = profile
                updated.deficitPercent = deficit
                try await store.saveProfile(updated)
                showingOtherPlans = false
            } catch { errorText = error.localizedDescription }
        }
    }
}
