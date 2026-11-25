import SwiftUI

// All experimental explanations stay in Developer settings, away from public charts.
struct ForecastCalibrationDetailsView: View {
    @Environment(HealthEnergy.self) private var health
    @Environment(FoodStore.self) private var store
    @Environment(\.foodUnits) private var units

    private var assessment: ForecastCalibrationAssessment? { health.forecastAssessment(using: store) }
    private var calibration: ForecastCalibration? { assessment?.calibration }
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 20, alignment: .topLeading)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                paceCard
                if let assessment {
                    comparisonCard(assessment)
                    adjustmentCard(assessment)
                }
                compositionCard
                sourcesCard
            }
            .padding()
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Forecast details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var paceCard: some View {
        ForecastDetailCard("Resulting pace", symbol: "chart.line.uptrend.xyaxis", info: paceExplanation) {
            if let profile = store.profile {
                let budget = health.representativeBudget(for: profile)
                let percent = calibration?.projectionDeficitPercent(for: budget) ?? Double(profile.deficitPercent)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(number(percent, decimals: 1))%")
                            .font(.largeTitle.bold()).monospacedDigit()
                        Text("forecast deficit").font(.headline).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(number(percent, decimals: 1))%")
                            .font(.largeTitle.bold()).monospacedDigit()
                        Text("forecast deficit").font(.headline).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("Selected plan")
                    Spacer()
                    Text("\(profile.deficitPercent)% deficit").fontWeight(.semibold).monospacedDigit()
                }
                .font(.subheadline)
                Divider()
                if let calibration {
                    Label(calibration.adjustmentDescription,
                          systemImage: abs(calibration.correctionKcal.rounded()) < 1 ? "equal.circle" : (calibration.correctionKcal < 0 ? "arrow.down.right" : "arrow.up.right"))
                        .font(.subheadline)
                } else {
                    Label("Standard forecast for now", systemImage: "clock")
                        .font(.subheadline.weight(.medium))
                    if assessment?.diagnostics.isRejected == true {
                        note("The inferred mismatch exceeds 1,000 kcal/day. The adjustment has been rejected and the standard energy gap is used.")
                    } else {
                        note("There is not enough consistent food and Health history to calibrate the energy gap yet.")
                    }
                }
            } else {
                note("Add your details to see the resulting forecast pace.")
            }
        }
    }

    private func comparisonCard(_ assessment: ForecastCalibrationAssessment) -> some View {
        let data = assessment.diagnostics
        return ForecastDetailCard(calibrationTitle(assessment.windowDays), symbol: "equal.square", info: calibrationExplanation(data)) {
            Text("Inputs: \(day(data.inputStart)) – \(day(data.inputEnd.addingTimeInterval(-1)))")
                .font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                metric("Health TDEE", kcal(data.meanTDEEKcal), detail: "kcal/day · resting + active energy")
                metric("Logged food", kcal(data.meanLoggedKcal), detail: "kcal/day")
                if let profile = store.profile {
                    let balance = data.allowanceBalance(deficitPercent: profile.deficitPercent)
                    metric(balance.remainingKcal < 0 ? "Over allowance" : "Remaining allowance",
                           kcal(abs(balance.remainingKcal)),
                           detail: "kcal/day · \(balance.remainingPercent.map { number(abs($0), decimals: 1) + "% of allowance" } ?? "no allowance reference")")
                }
                deficitMetric("Recorded balance", kcal: data.recordedDeficitKcal,
                              percent: data.recordedDeficitPercent)
            }
            Divider()
            coverageSummary(assessment)
        }
    }

    private func adjustmentCard(_ assessment: ForecastCalibrationAssessment) -> some View {
        let data = assessment.diagnostics
        return ForecastDetailCard("Forecast adjustment", symbol: "slider.horizontal.3", info: adjustmentExplanation(data)) {
            deficitMetric("Inferred deficit", kcal: data.weightEquivalentDeficitKcal,
                          percent: data.weightEquivalentDeficitPercent)
            Label(data.usesBodyComposition ? "Inferred from weight + body-fat changes" : "Inferred from weight changes",
                  systemImage: "waveform.path")
                .font(.subheadline.weight(.medium))
            Divider()
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                metric("Raw mismatch", kcal(abs(data.rawCorrectionKcal)),
                       detail: "kcal/day \(direction(data.rawCorrectionKcal)) deficit")
                metric("Deficit difference", number(abs(data.mismatchPercentagePoints), decimals: 1),
                       detail: "percentage points \(data.rawCorrectionKcal < 0 ? "lower" : "higher")",
                       info: "\(number(data.recordedDeficitPercent, decimals: 1))% recorded → \(number(data.weightEquivalentDeficitPercent, decimals: 1))% inferred. The difference is in percentage points, not a relative percentage change. Both use the same Health TDEE reference.")
            }
            Divider()
            if let calibration = assessment.calibration {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    metric("Mismatch applied", "\(number(data.influence * 100, decimals: 1))%",
                           detail: "of the raw mismatch", info: adjustmentWeightExplanation(assessment))
                    metric("Applied to forecast", kcal(abs(calibration.correctionKcal)),
                           detail: "kcal/day \(direction(calibration.correctionKcal)) deficit", emphasis: true)
                }
            } else {
                Label("Adjustment rejected", systemImage: "exclamationmark.triangle")
                    .font(.headline).foregroundStyle(.orange)
                note("Mismatch exceeds ±1,000 kcal/day. Using the standard energy gap.")
            }
        }
    }

    private func coverageSummary(_ assessment: ForecastCalibrationAssessment) -> some View {
        let data = assessment.diagnostics
        let window = DateInterval(start: data.inputStart, end: data.inputEnd)
        let fatDays = HealthHistory.lastReadingEachDay(health.bodyFatForForecastCalibration.filter {
            $0.date >= window.start && $0.date < window.end && $0.value.isFinite && $0.value > 0 && $0.value < 100
        }).count
        let paired = BodyCompositionTrend.pairedReadings(weights: health.weightsForForecastCalibration,
            bodyFat: health.bodyFatForForecastCalibration, within: window)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("History coverage").font(.headline)
                Spacer()
                InfoDisclosure(title: "History coverage", message: "Percentages show the share of input days with data, out of 100%. Readings are counted once per day.\n\nFood + energy requires food logs, resting energy and active energy on the same day. Weight shows the usable weekly groups in the fit. Body fat counts days with body-fat readings; weight + body fat counts paired days for composition analysis. Fat mass needs both readings on the same day.\n\nThese coverage percentages are separate from the forecast weighting factors.")
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                coverageMetric("Food + energy", days: assessment.energyDays, total: assessment.windowDays)
                coverageMetric("Weight", days: assessment.weightDays, total: assessment.windowDays,
                               detail: "\(assessment.weightWeeks) usable weekly groups")
                coverageMetric("Body fat", days: fatDays, total: assessment.windowDays)
                coverageMetric("Weight + body fat", days: paired.count, total: assessment.windowDays)
            }
        }
    }

    private var compositionCard: some View {
        ForecastDetailCard("Body-composition trend", symbol: "figure.stand", info: compositionExplanation) {
            if health.isRefreshingComposition {
                ProgressView("Reading recent Health history…").font(.subheadline)
            }
            if let trend = health.compositionTrend {
                Text("Window: \(day(trend.window.start)) – \(day(trend.window.end.addingTimeInterval(-1)))")
                    .font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    metric("Fat", units.weight(abs(trend.fatChangeKgPerDay * 7)),
                           detail: trend.fatChangeKgPerDay < 0 ? "lost per week" : "gained per week")
                    let lean = trend.leanChangeKgPerDay * 7
                    metric("Fat-free mass", abs(lean) < 0.05 ? "Stable" : units.weight(abs(lean)),
                           detail: abs(lean) < 0.05 ? "approximately" : (lean < 0 ? "lost per week" : "gained per week"))
                    metric("Paired readings", "\(trend.readings.count)", detail: "days across \(trend.weekCount) weeks")
                    metric("Personal trend weight", percentage(trend.confidence), detail: "starting personal share",
                           info: compositionWeightExplanation(trend))
                }
                if let body = currentBody(for: trend) {
                    let split = trend.split(for: body)
                    Divider()
                    HStack {
                        Text("Compared with Forbes").font(.headline)
                        Spacer()
                        InfoDisclosure(title: "Compared with Forbes", message: forbesExplanation(split))
                    }
                    note("Fat-free mass per \(units.weight(1)) fat lost")
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        leanMetric("Forbes", kg: split.forbesLeanPerFat)
                        leanMetric("Your fitted split", kg: split.personalLeanPerFat)
                        leanMetric("Used for forecast", kg: split.usedLeanPerFat)
                    }
                    note("Blend: \(percentage(split.personalShare)) personal · \(percentage(1 - split.personalShare)) Forbes")
                }
            } else {
                Label("Using the Forbes split", systemImage: "chart.xyaxis.line")
                    .font(.subheadline.weight(.medium))
                note("No reliable composition trend yet.")
            }
            if let error = health.compositionHistoryError {
                Label("Recent history could not be refreshed: \(error)", systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func currentBody(for trend: BodyCompositionTrend) -> ForbesBodyComposition? {
        guard let profile = store.profile else { return trend.readings.last?.body }
        let weight = health.smoothedWeightKg ?? health.usableLatestWeightKg ?? profile.weightKg
        return health.bodyCompositionBaseline(for: profile).flatMap {
            ForbesBodyComposition(weightKg: weight, bodyFatPercentage: $0.composition.bodyFatPercentage)
        } ?? trend.readings.last?.body
    }

    private func leanMetric(_ title: String, kg: Double) -> some View {
        metric(title, units.weight(abs(kg)), detail: abs(kg) < 0.005 ? "fat-free mass · approximately stable" : "fat-free mass \(kg < 0 ? "gained" : "lost")")
    }

    private func coverageMetric(_ title: String, days: Int, total: Int, detail: String? = nil) -> some View {
        metric(title, percentage(total > 0 ? Double(days) / Double(total) : 0),
               detail: "\(days) of \(total) days" + (detail.map { " · " + $0 } ?? ""))
    }

    private func preciseWeight(_ kg: Double) -> String {
        "\(units.weightValue(kg).formatted(.number.precision(.fractionLength(2)))) \(units.weightSymbol)"
    }

    private func percentage(_ fraction: Double) -> String { "\(number(fraction * 100, decimals: 1))%" }
    private func calibrationTitle(_ days: Int) -> String {
        days.isMultiple(of: 7) ? "Calibration · last \(days / 7) weeks" : "Calibration · last \(days) completed days"
    }

    private var paceExplanation: String {
        """
        Experimental, off by default and local to this iPhone. These app heuristics are not a validated physiological model.

        Only forecast curves, body-fat projections and estimated dates change. Your calorie allowance, selected plan and logged totals stay the same.

        The forecast-implied percentage divides the forecast gap by your unchanged calorie allowance plus that gap. It describes the percentage implied by the curve, not a measurement of true TDEE.

        Calibration compares Health energy minus actual logged food with the observed trend, not just your selected deficit. The future plan assumes you eat your selected allowance; it does not assume you keep leaving recent unused calories.

        All composition history stays on this device. Public chart labels describe the standard model; advanced calibration is explained only here in Developer settings.
        """
    }

    private func calibrationExplanation(_ data: ForecastCalibrationDiagnostics) -> String {
        """
        Uses up to 42 completed days (6 weeks), starting no earlier than your first use of 00Food. Earlier history and today’s partial data are excluded.

        The trend is fitted between weekly medians, \(day(data.fitStart)) – \(day(data.fitEnd)). Energy and allowance values are daily averages over that fitted span, using your current plan. Health TDEE is resting plus active energy. Remaining allowance compares logged food with your current plan’s allowance; recorded balance compares it with TDEE before the plan’s deficit.

        The fit needs at least 28 days of history, food plus paired resting/active Health energy on 90% of days, and 14 weight days across at least four weekly groups. Weekly medians and a robust trend fit compare observed change with recorded energy balance. The few missing energy days use the recorded average.
        """
    }

    private func adjustmentExplanation(_ data: ForecastCalibrationDiagnostics) -> String {
        """
        The inferred deficit is the energy gap that would explain your fitted body changes under this model. It is not measured calorie burn. It uses the same Health TDEE reference as the recorded balance in the calibration card.

        \(data.usesBodyComposition ? "This fit uses weight and body-fat changes." : "This fit uses weight changes; recent paired composition data is insufficient for the energy fit.") Recent paired composition data uses about 9,440 kcal/kg fat and 1,816 kcal/kg fat-free mass. Otherwise the weight-only energy fit remains. Stable weight with falling fat can therefore be recognized as recomposition.

        Raw mismatch is inferred minus recorded deficit. Negative means less deficit and slower loss; positive means more deficit and faster loss. Only the displayed share of that mismatch is applied to the forecast.

        A raw mismatch above ±1,000 kcal/day is rejected before weighting. Values within the limit are used without a cap. Missing, stale or very noisy history uses the standard energy gap. Projections flatten if the adjusted gap is zero or negative; weight gain is not modeled.

        These diagnostics cannot separate food-estimation error, Watch error, water changes or model error. Missing food logs and water changes can still distort estimates.
        """
    }

    private func adjustmentWeightExplanation(_ assessment: ForecastCalibrationAssessment) -> String {
        let data = assessment.diagnostics
        let applied = assessment.calibration.map { "\(kcal(abs(data.rawCorrectionKcal))) × \(percentage(data.influence)) ≈ \(kcal(abs($0.correctionKcal))) kcal/day \(direction($0.correctionKcal)) deficit." } ?? "No adjustment is applied because this mismatch was rejected."
        guard let weight = data.weighting else { return applied }
        return """
        \(applied)

        History length: \(percentage(weight.historyFactor)). \(weight.weeks) usable weekly groups ÷ 6, up to 100%. A full six-week window gets full history weight.

        Food + energy coverage: \(percentage(weight.energyCoverage)). \(assessment.energyDays) of \(assessment.windowDays) completed days have food, resting energy and active energy.

        Weight readings: \(percentage(weight.weightCoverage)). \(weight.weightDays) days ÷ 28, up to 100%.

        Trend consistency: \(percentage(weight.consistency)). 1 − \(preciseWeight(weight.scatterKg)) scatter ÷ \(preciseWeight(0.75)) tolerance, down to 0%.

        \(percentage(weight.historyFactor)) × \(percentage(weight.energyCoverage)) × \(percentage(weight.weightCoverage)) × \(percentage(weight.consistency)) ≈ \(percentage(weight.fraction)). These experimental weighting rules temper the adjustment; they are not measured accuracy or a probability that the estimate is correct.
        """
    }

    private var compositionExplanation: String {
        """
        Uses the same recent window and weekly groups as the energy fit: up to 42 completed days (6 weeks), starting no earlier than your first use of 00Food. Only paired weight/body-fat dates contribute. Older readings and today’s partial data are excluded.

        Weekly medians and a robust fit give the fat and fat-free mass trends. Newer readings carry more weight. At least 14 paired days, four weekly groups, a 28-day span and a paired reading in the last seven days are needed. Noisy or sparse history pulls the split toward Forbes; without a reliable personal trend, Forbes is used when body-fat data is available.

        Fat-free mass includes water and other tissue. It is not a direct muscle measurement, and the trend does not establish that exercise caused muscle preservation. Negative fat-free mass change in the existing forecast summary means a modeled gain.
        """
    }

    private func compositionWeightExplanation(_ trend: BodyCompositionTrend) -> String {
        let weight = trend.weighting
        return """
        This percentage controls how much your fitted fat/lean split contributes. The remainder comes from Forbes. It is not the percentage of weight lost as fat or an accuracy score.

        History length: \(percentage(weight.historyFactor)). \(weight.weeks) usable weekly groups ÷ 6, up to 100%. A full six-week window gets full history weight.

        Recent paired readings: \(percentage(weight.readingFactor)). \(number(weight.effectiveDays, decimals: 1)) recency-weighted reading days ÷ 28, up to 100%. Each reading’s weight halves after 90 days; only the shared recent window is used.

        Trend consistency: \(percentage(weight.consistency)). 1 − \(preciseWeight(weight.scatterKg)) scatter ÷ \(preciseWeight(weight.noiseLimitKg)) tolerance. Scatter uses the noisier of the fat and fat-free mass fits. The tolerance is the larger of \(units.weight(0.75)) and 1.5% of median weight.

        \(percentage(weight.historyFactor)) × \(percentage(weight.readingFactor)) × \(percentage(weight.consistency)) ≈ \(percentage(weight.fraction)). These experimental factors reduce the personal share for shorter, sparser or noisier history.

        The energy fit separately uses this data weight to blend composition-based tissue energy with its weight-only estimate. This is independent of the adjustment share.
        """
    }

    private func forbesExplanation(_ split: BodyCompositionSplit) -> String {
        """
        Approximate fat-free mass change per \(units.weight(1)) of fat lost, at your current fat mass. These values describe a split, not a weekly rate.

        Forbes is the standard model’s split. Your fitted split comes from the recent composition trend. Used for forecast blends the two: \(percentage(split.personalShare)) personal + \(percentage(1 - split.personalShare)) Forbes.

        The personal share gradually decreases if projected fat mass falls below its recent reference. The learned ratio is bounded between gaining 1 kg and losing 3 kg of fat-free mass per kg of fat lost. This is an experimental guardrail, not a physiological limit.
        """
    }

    private var sourcesCard: some View {
        ForecastDetailCard("Research", symbol: "book") {
            Link("Research background", destination: URL(string: "https://pubmed.ncbi.nlm.nih.gov/21562087/")!)
            Link("Body-composition energy model", destination: URL(string: "https://www.niddk.nih.gov/-/media/Files/BWP/Hall_Lancet_Web_Appendix.pdf")!)
            Link("Scale accuracy research", destination: URL(string: "https://pmc.ncbi.nlm.nih.gov/articles/PMC8122302/")!)
        }
        .tint(.blue)
    }

    private func metric(_ title: String, _ value: String, detail: String, emphasis: Bool = false,
                        info: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                if let info { InfoDisclosure(title: title, message: info) }
            }
            .frame(minHeight: 30, alignment: .leading)
            Text(value).font(emphasis ? .title.bold() : .title2.weight(.semibold))
                .monospacedDigit().foregroundStyle(emphasis ? Color.blue : Color.primary)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: info == nil ? .combine : .contain)
    }

    private func deficitMetric(_ title: String, kcal value: Double, percent: Double) -> some View {
        metric(title, "\(number(abs(percent), decimals: 1))%",
               detail: "of Health TDEE · \(kcal(abs(value))) kcal/day \(value < 0 ? "surplus" : "deficit")")
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func direction(_ value: Double) -> String { value < 0 ? "less" : "more" }
    private func kcal(_ value: Double) -> String { number(value) }
    private func number(_ value: Double, decimals: Int = 0) -> String {
        value.formatted(.number.precision(.fractionLength(decimals)))
    }
    private func day(_ date: Date) -> String { date.formatted(.dateTime.day().month(.abbreviated).year()) }
}

private struct ForecastDetailCard<Content: View>: View {
    let title: String
    let symbol: String
    let info: String?
    @ViewBuilder let content: Content

    init(_ title: String, symbol: String, info: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.info = info
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: symbol)
                    .font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if let info { InfoDisclosure(title: title, message: info) }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }
}
