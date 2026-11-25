import SwiftUI

// All experimental explanations stay in Developer settings, away from public charts.
struct ForecastCalibrationDetailsView: View {
    @Environment(HealthEnergy.self) private var health
    @Environment(FoodStore.self) private var store
    @Environment(\.foodUnits) private var units

    private var calibration: ForecastCalibration? { health.forecastCalibration(using: store) }
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 20, alignment: .topLeading)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                paceCard
                if let profile = store.profile,
                   let average = CalorieBalanceAverage.lastSevenCompletedDays(in:
                    health.calorieHistory(profile: profile, store: store, daysIncludingToday: 8)) {
                    recentEnergyCard(average)
                }
                if let calibration {
                    if let data = calibration.diagnostics {
                        comparisonCard(data)
                        adjustmentCard(calibration, data: data)
                    }
                    coverageCard(calibration)
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
                    note("There is not enough consistent food and Health history to calibrate the energy gap yet.")
                }
                note("Only the forecast changes. Your calorie allowance, selected plan and logged totals stay the same.")
            } else {
                note("Add your details to see the resulting forecast pace.")
            }
        }
    }

    private func recentEnergyCard(_ average: CalorieBalanceAverage) -> some View {
        ForecastDetailCard("Last \(average.dayCount) completed days", symbol: "calendar") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                metric("Health TDEE", kcal(average.tdeeKcalPerDay), detail: "kcal/day")
                metric("Logged food", kcal(average.eatenKcalPerDay), detail: "kcal/day")
                metric(average.remainingKcalPerDay < 0 ? "Over allowance" : "Remaining allowance",
                       kcal(abs(average.remainingKcalPerDay)),
                       detail: "kcal/day · \(number(abs(average.remainingPercent), decimals: 1))% of allowance")
                deficitMetric("Recorded balance", kcal: average.recordedDeficitKcalPerDay,
                              percent: average.tdeeDeficitPercent)
            }
            note("These are the same averages and Health fallbacks used in Calories over time. Remaining calories are a daily average, not the total for the week.")
        }
    }

    private func comparisonCard(_ data: ForecastCalibrationDiagnostics) -> some View {
        ForecastDetailCard("Calibration comparison", symbol: "equal.square") {
            Text("\(day(data.fitStart)) – \(day(data.fitEnd))")
                .font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                metric("Health TDEE", kcal(data.meanTDEEKcal), detail: "kcal/day")
                metric("Logged food", kcal(data.meanLoggedKcal), detail: "kcal/day")
                deficitMetric("Recorded balance", kcal: data.recordedDeficitKcal,
                              percent: data.recordedDeficitPercent)
                deficitMetric("Trend equivalent", kcal: data.weightEquivalentDeficitKcal,
                              percent: data.weightEquivalentDeficitPercent)
            }
            Label(data.usesBodyComposition ? "Fat + fat-free mass energy fit" : "Weight-only energy fit",
                  systemImage: "waveform.path")
                .font(.subheadline.weight(.medium))
            if !data.usesBodyComposition {
                note("Recent paired composition data is insufficient for the energy fit.")
            }
            note("Both percentages use the same Health TDEE reference and weight-fit period. The trend equivalent is inferred by the model, not measured calorie burn. Any missing days use the calibration’s mean-filled values.")
        }
    }

    private func adjustmentCard(_ calibration: ForecastCalibration, data: ForecastCalibrationDiagnostics) -> some View {
        ForecastDetailCard("From mismatch to adjustment", symbol: "slider.horizontal.3") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                metric("Raw mismatch", kcal(abs(data.rawCorrectionKcal)),
                       detail: "kcal/day \(direction(data.rawCorrectionKcal)) deficit")
                metric("Percentage difference", "\(number(abs(data.mismatchPercentagePoints), decimals: 1)) pp",
                       detail: "\(direction(data.rawCorrectionKcal)) deficit vs Health TDEE")
                metric("After cap", kcal(abs(data.limitedCorrectionKcal)),
                       detail: "kcal/day \(direction(data.limitedCorrectionKcal)) deficit")
                metric("Influence", "\(number(data.influence * 100, decimals: 1))%",
                       detail: "Applied after the cap")
            }
            Divider()
            metric("Applied to forecast", kcal(abs(calibration.correctionKcal)),
                   detail: "kcal/day \(direction(calibration.correctionKcal)) deficit",
                   emphasis: true)
            note("The raw mismatch is uncapped. A ±1,000 kcal/day cap is applied before damping for shorter, sparser or noisier history. There is no separate percentage-of-TDEE cap.")
        }
    }

    private func coverageCard(_ calibration: ForecastCalibration) -> some View {
        ForecastDetailCard("Calibration history", symbol: "checkmark.rectangle.stack") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                metric("Food + Health", "\(calibration.energyDays)", detail: "paired days")
                metric("Weight", "\(calibration.weightDays)", detail: "days across \(calibration.weightWeeks) weeks")
            }
            if let data = calibration.diagnostics {
                let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: data.inputEnd) ?? data.inputEnd
                note("Input window: \(day(data.inputStart)) – \(day(lastDay)).")
            }
        }
    }

    private var compositionCard: some View {
        ForecastDetailCard("Body-composition trend", symbol: "figure.stand") {
            if health.isRefreshingComposition {
                ProgressView("Reading full Health history…").font(.subheadline)
            }
            if let trend = health.compositionTrend {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    metric("Fat", units.weight(abs(trend.fatChangeKgPerDay * 7)),
                           detail: trend.fatChangeKgPerDay < 0 ? "lost per week" : "gained per week")
                    let lean = trend.leanChangeKgPerDay * 7
                    metric("Fat-free mass", abs(lean) < 0.05 ? "Stable" : units.weight(abs(lean)),
                           detail: abs(lean) < 0.05 ? "approximately" : (lean < 0 ? "lost per week" : "gained per week"))
                    metric("Paired readings", "\(trend.readings.count)", detail: "days across \(trend.weekCount) weeks")
                    metric("Trend influence", "\(number(trend.confidence * 100))%", detail: "Personal split vs Forbes")
                }
                note("\(day(trend.firstDate)) – \(day(trend.lastDate)). All readable paired weight/body-fat dates contribute, including dates before you joined 00Food. Older dates carry less weight.")
            } else {
                Label("Using the Forbes split", systemImage: "chart.xyaxis.line")
                    .font(.subheadline.weight(.medium))
                note("There is no reliable composition trend yet. The fat/fat-free mass split uses Forbes when body-fat data is available.")
            }
            if let error = health.compositionHistoryError {
                Label("Full history could not be refreshed: \(error)", systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var methodologyCard: some View {
        ForecastDetailCard("How to read these estimates", symbol: "info.circle") {
            note("Experimental, off by default and local to this iPhone. These app heuristics are not a validated physiological model.")
            DisclosureGroup("Resulting pace & energy balance") {
                explanation("The forecast-implied percentage divides the forecast gap by your unchanged calorie allowance plus that gap. It describes the percentage implied by the curve, not a measurement of true TDEE.")
                explanation("Calibration compares Health energy minus actual logged food with the observed trend, not just your selected deficit. The future plan assumes you eat your selected allowance; it does not assume you keep leaving the recent unused calories.")
                explanation("Projections flatten if the adjusted gap is zero or negative; weight gain is not modeled. Missing, stale or very noisy history uses the standard forecast.")
            }
            Divider()
            DisclosureGroup("History & smoothing") {
                explanation("The energy fit uses up to 42 completed days, with at least 28 days of history, food plus paired resting/active Health energy on 90% of days, and 14 weight days across at least four weekly groups. Weekly medians and a robust trend fit compare observed change with recorded energy balance. The few missing energy days use the recorded average.")
                explanation("The composition split uses all readable paired Health dates, weekly medians and a robust fit with a 90-day recency half-life. Older dates remain in the fit. It needs at least 14 paired days, four weekly groups, a 28-day span and a paired reading in the last seven days. Noisy or sparse history pulls the split toward Forbes.")
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
                explanation("All full-history composition data stays on this device. Calorie allowances, selected pace and logged totals never change. Public chart labels describe the standard model; advanced calibration is explained only here in Developer settings.")
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
