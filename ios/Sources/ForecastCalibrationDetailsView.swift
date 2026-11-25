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
                methodologyCard
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
        ForecastDetailCard("Resulting pace", symbol: "chart.line.uptrend.xyaxis") {
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
                note("Only the forecast changes. Your calorie allowance, selected plan and logged totals stay the same.")
            } else {
                note("Add your details to see the resulting forecast pace.")
            }
        }
    }

    private func comparisonCard(_ assessment: ForecastCalibrationAssessment) -> some View {
        let data = assessment.diagnostics
        return ForecastDetailCard(calibrationTitle(assessment.windowDays), symbol: "equal.square") {
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
            note("The trend is fitted between weekly medians, \(day(data.fitStart)) – \(day(data.fitEnd)). Energy and allowance values above are daily averages over that fitted span, using your current plan. Missing energy days use the recorded average.")
            Divider()
            coverageSummary(assessment)
        }
    }

    private func adjustmentCard(_ assessment: ForecastCalibrationAssessment) -> some View {
        let data = assessment.diagnostics
        return ForecastDetailCard("Forecast adjustment", symbol: "slider.horizontal.3") {
            deficitMetric("Inferred deficit", kcal: data.weightEquivalentDeficitKcal,
                          percent: data.weightEquivalentDeficitPercent)
            Label(data.usesBodyComposition ? "Inferred from weight + body-fat changes" : "Inferred from weight changes",
                  systemImage: "waveform.path")
                .font(.subheadline.weight(.medium))
            note("The inferred deficit is the energy gap that would explain your fitted body changes under this model. It is not measured calorie burn. It uses the same Health TDEE reference as the recorded balance in the calibration card.")
            Divider()
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                metric("Raw mismatch", kcal(abs(data.rawCorrectionKcal)),
                       detail: "kcal/day \(direction(data.rawCorrectionKcal)) deficit")
                metric("Deficit difference", number(abs(data.mismatchPercentagePoints), decimals: 1),
                       detail: "percentage points \(data.rawCorrectionKcal < 0 ? "lower" : "higher")")
            }
            note("\(number(data.recordedDeficitPercent, decimals: 1))% recorded → \(number(data.weightEquivalentDeficitPercent, decimals: 1))% inferred. The difference is in percentage points, not a relative percentage change.")
            Divider()
            if let calibration = assessment.calibration {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    metric("Mismatch applied", "\(number(data.influence * 100, decimals: 1))%",
                           detail: "Share of the raw mismatch used")
                    metric("Applied to forecast", kcal(abs(calibration.correctionKcal)),
                           detail: "kcal/day \(direction(calibration.correctionKcal)) deficit", emphasis: true)
                }
                note("\(kcal(abs(data.rawCorrectionKcal))) × \(number(data.influence * 100, decimals: 1))% = \(kcal(abs(calibration.correctionKcal))) kcal/day. This weight tempers the adjustment; it is not a probability that the estimate is correct.")
            } else {
                Label("Adjustment rejected", systemImage: "exclamationmark.triangle")
                    .font(.headline).foregroundStyle(.orange)
                note("The raw mismatch exceeds ±1,000 kcal/day. No calibrated energy adjustment is calculated; the standard energy gap remains in use. Review the underlying food and Health data.")
            }
            if let weight = data.weighting {
                DisclosureGroup("How the adjustment weight is calculated") {
                    VStack(alignment: .leading, spacing: 14) {
                        weightingRow("History length", weight.historyFactor,
                                     "\(weight.weeks) usable weekly groups ÷ 6, up to 100%. A full six-week window gets full history weight.")
                        weightingRow("Food + energy coverage", weight.energyCoverage,
                                     "\(assessment.energyDays) of \(assessment.windowDays) completed days have food, resting energy and active energy.")
                        weightingRow("Weight readings", weight.weightCoverage,
                                     "\(weight.weightDays) days ÷ 28, up to 100%.")
                        weightingRow("Trend consistency", weight.consistency,
                                     "1 − \(preciseWeight(weight.scatterKg)) scatter ÷ \(preciseWeight(0.75)) tolerance, down to 0%.")
                        note("\(percentage(weight.historyFactor)) × \(percentage(weight.energyCoverage)) × \(percentage(weight.weightCoverage)) × \(percentage(weight.consistency)) ≈ \(percentage(weight.fraction)). These are experimental weighting rules, not measured accuracy.")
                    }.padding(.top, 12)
                }
            }
            note("A raw mismatch above ±1,000 kcal/day is rejected before weighting. Values within the limit are used without a cap.")
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
            Text("History coverage").font(.headline)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                coverageMetric("Food + energy", days: assessment.energyDays, total: assessment.windowDays,
                               detail: "food logs + resting and active Health energy")
                coverageMetric("Weight", days: assessment.weightDays, total: assessment.windowDays,
                               detail: "\(assessment.weightWeeks) usable weekly groups")
                coverageMetric("Body fat", days: fatDays, total: assessment.windowDays,
                               detail: "body-fat readings")
                coverageMetric("Weight + body fat", days: paired.count, total: assessment.windowDays,
                               detail: "paired readings for composition analysis")
            }
            note("Percentages show the share of input days with data, out of 100%. Readings are counted once per day. Fat mass needs weight and body fat on the same day. These coverage percentages are separate from the forecast weighting factors.")
        }
    }

    private var compositionCard: some View {
        ForecastDetailCard("Body-composition trend", symbol: "figure.stand") {
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
                    metric("Personal trend weight", percentage(trend.confidence), detail: "Starting share from your fitted split")
                }
                note("This percentage controls how much your fitted fat/lean split contributes. The remainder comes from Forbes. It is not the percentage of weight lost as fat or an accuracy score.")
                compositionWeightDetails(trend)
                if let body = currentBody(for: trend) {
                    let split = trend.split(for: body)
                    Divider()
                    Text("Compared with Forbes").font(.headline)
                    note("Approximate fat-free mass change per \(units.weight(1)) of fat lost, at your current fat mass:")
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        leanMetric("Forbes", kg: split.forbesLeanPerFat)
                        leanMetric("Your fitted split", kg: split.personalLeanPerFat)
                        leanMetric("Used for forecast", kg: split.usedLeanPerFat)
                    }
                    note("Current blend: \(percentage(split.personalShare)) your fitted split + \(percentage(1 - split.personalShare)) Forbes. The personal share gradually decreases if projected fat mass falls below its recent reference. The fitted split is subject to the model’s existing bounds.")
                }
                note("Only paired dates within the shared calibration window contribute. Older readings and today’s partial data are excluded. Fat-free mass includes water and other tissue; it is not a direct muscle measurement.")
            } else {
                Label("Using the Forbes split", systemImage: "chart.xyaxis.line")
                    .font(.subheadline.weight(.medium))
                note("There is no reliable composition trend yet. The fat/fat-free mass split uses Forbes when body-fat data is available.")
            }
            if let error = health.compositionHistoryError {
                Label("Recent history could not be refreshed: \(error)", systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func compositionWeightDetails(_ trend: BodyCompositionTrend) -> some View {
        let weight = trend.weighting
        return DisclosureGroup("How the personal trend weight is calculated") {
            VStack(alignment: .leading, spacing: 14) {
                weightingRow("History length", weight.historyFactor,
                             "\(weight.weeks) usable weekly groups ÷ 6, up to 100%. A full six-week window gets full history weight.")
                weightingRow("Recent paired readings", weight.readingFactor,
                             "\(number(weight.effectiveDays, decimals: 1)) recency-weighted reading days ÷ 28, up to 100%. Each reading’s weight halves after 90 days; only the shared recent window is used.")
                weightingRow("Trend consistency", weight.consistency,
                             "1 − \(preciseWeight(weight.scatterKg)) scatter ÷ \(preciseWeight(weight.noiseLimitKg)) tolerance. Scatter uses the noisier of the fat and fat-free mass fits.")
                note("\(percentage(weight.historyFactor)) × \(percentage(weight.readingFactor)) × \(percentage(weight.consistency)) ≈ \(percentage(weight.fraction)). These experimental factors reduce the personal share for shorter, sparser or noisier history. The tolerance is the larger of \(units.weight(0.75)) and 1.5% of median weight.")
                note("The energy fit separately uses this data weight to blend composition-based tissue energy with its weight-only estimate. This is independent of the adjustment share shown above.")
            }.padding(.top, 12)
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

    private func weightingRow(_ title: String, _ fraction: Double, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).fontWeight(.medium)
                Spacer()
                Text(percentage(fraction)).monospacedDigit()
            }.font(.subheadline)
            note(detail)
        }
        .accessibilityElement(children: .combine)
    }

    private func coverageMetric(_ title: String, days: Int, total: Int, detail: String) -> some View {
        metric(title, percentage(total > 0 ? Double(days) / Double(total) : 0),
               detail: "\(days) of \(total) days · \(detail)")
    }

    private func preciseWeight(_ kg: Double) -> String {
        "\(units.weightValue(kg).formatted(.number.precision(.fractionLength(2)))) \(units.weightSymbol)"
    }

    private func percentage(_ fraction: Double) -> String { "\(number(fraction * 100, decimals: 1))%" }
    private func calibrationTitle(_ days: Int) -> String {
        days.isMultiple(of: 7) ? "Calibration · last \(days / 7) weeks" : "Calibration · last \(days) completed days"
    }

    private var methodologyCard: some View {
        ForecastDetailCard("How to read these estimates", symbol: "info.circle") {
            note("Experimental, off by default and local to this iPhone. These app heuristics are not a validated physiological model.")
            DisclosureGroup("Resulting pace & energy balance") {
                explanation("The forecast-implied percentage divides the forecast gap by your unchanged calorie allowance plus that gap. It describes the percentage implied by the curve, not a measurement of true TDEE.")
                explanation("Calibration compares Health energy minus actual logged food with the observed trend, not just your selected deficit. The future plan assumes you eat your selected allowance; it does not assume you keep leaving the recent unused calories.")
                explanation("Projections flatten if the adjusted gap is zero or negative; weight gain is not modeled. Missing, stale or very noisy history uses the standard energy gap. A raw mismatch above ±1,000 kcal/day is rejected, rather than capped into a usable adjustment.")
            }
            Divider()
            DisclosureGroup("History & smoothing") {
                explanation("The energy fit uses up to 42 completed days (6 weeks), with at least 28 days of history, food plus paired resting/active Health energy on 90% of days, and 14 weight days across at least four weekly groups. Weekly medians and a robust trend fit compare observed change with recorded energy balance. The few missing energy days use the recorded average.")
                explanation("The composition split uses the same recent window and weekly groups as the energy fit: up to 42 completed days (6 weeks), starting no earlier than your first use of 00Food. It uses weekly medians and a robust fit, with newer readings weighted more heavily. Earlier history and today’s readings are excluded. It needs at least 14 paired days, four weekly groups, a 28-day span and a paired reading in the last seven days. Noisy or sparse history pulls the split toward Forbes.")
            }
            Divider()
            DisclosureGroup("Fat & fat-free mass model") {
                explanation("The learned ratio is bounded between gaining 1 kg and losing 3 kg of fat-free mass per kg of fat lost. This is an experimental guardrail, not a physiological limit. The personal split gradually returns toward Forbes as projected fat mass leaves the current range.")
                explanation("Recent paired composition data also improves the energy fit using about 9,440 kcal/kg fat and 1,816 kcal/kg fat-free mass. Otherwise the weight-only energy fit remains. Stable weight with falling fat can therefore be recognized as recomposition.")
                explanation("Negative fat-free mass change in the existing forecast summary means a modeled gain.")
            }
            Divider()
            DisclosureGroup("Limits & privacy") {
                explanation("These diagnostics cannot separate food-estimation error, Watch error, water changes or model error. Missing food logs and water changes can still distort estimates.")
                explanation("The trend does not establish that exercise caused muscle preservation. Fat-free mass includes water and other tissue.")
                explanation("All composition history stays on this device. Calorie allowances, selected pace and logged totals never change. Public chart labels describe the standard model; advanced calibration is explained only here in Developer settings.")
            }
            .tint(.blue)
        }
    }

    private var sourcesCard: some View {
        ForecastDetailCard("Research", symbol: "book") {
            Link("Research background", destination: URL(string: "https://pubmed.ncbi.nlm.nih.gov/21562087/")!)
            Link("Body-composition energy model", destination: URL(string: "https://www.niddk.nih.gov/-/media/Files/BWP/Hall_Lancet_Web_Appendix.pdf")!)
            Link("Scale accuracy research", destination: URL(string: "https://pmc.ncbi.nlm.nih.gov/articles/PMC8122302/")!)
        }
        .tint(.blue)
    }

    private func metric(_ title: String, _ value: String, detail: String, emphasis: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(emphasis ? .title.bold() : .title2.weight(.semibold))
                .monospacedDigit().foregroundStyle(emphasis ? Color.blue : Color.primary)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func deficitMetric(_ title: String, kcal value: Double, percent: Double) -> some View {
        metric(title, "\(number(abs(percent), decimals: 1))%",
               detail: "of Health TDEE · \(kcal(abs(value))) kcal/day \(value < 0 ? "surplus" : "deficit")")
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func explanation(_ text: String) -> some View {
        note(text).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
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
    @ViewBuilder let content: Content

    init(_ title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: symbol)
                .font(.headline).accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }
}
