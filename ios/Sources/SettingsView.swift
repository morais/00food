import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(FoodStore.self) private var store
    @Environment(HealthEnergy.self) private var health
    @Environment(\.dismiss) private var dismiss
    @State private var showingAccount = false
    @State private var showingProfile = false
    @State private var showingDeveloper = false
    @State private var errorText: String?
    @State private var showingAgentSetup = false
    @State private var connectionError: String?
    @State private var requestingWorkoutAccess = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    Button("Your account") { showingAccount = true }
                    Button("Your details") { showingProfile = true }
                }
                Section("Your AI agent") {
                    Text("Bring your own agent to estimate foods and help you review your day. ChatGPT Work is recommended for automatic responses through MCP Events.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Connect your agent & set up events") { showingAgentSetup = true }
                    if let connectionError {
                        Text(connectionError).font(.footnote).foregroundStyle(.orange)
                    } else if store.hasLoadedConnections && store.connections.isEmpty {
                        Text("No connected agents yet.").foregroundStyle(.secondary)
                    }
                    if connectionError == nil {
                        ForEach(store.connections) { connection in
                            HStack(alignment: .top) {
                                AgentConnectionDetails(connection: connection)
                                Spacer()
                                Button("Revoke", role: .destructive) { revoke(connection) }
                            }
                        }
                    }
                }
                Section("Daily feedback") {
                    Toggle("Request a daily review", isOn: Binding(
                        get: { store.dailyFeedbackEnabled },
                        set: { store.setDailyFeedbackEnabled($0) }
                    ))
                    Text("When this is on, 00Food requests a background refresh after 12:15 a.m. to send the completed day and up to six earlier days to your private 00Food account. iOS decides when it runs. If the refresh is delayed, Health data is locked, or your phone is offline, it retries later or catches up when you open the app. This includes logged foods and calories, plus available Health totals for water, active and resting energy, weight, and body fat. Your connected agent can read these summaries and write feedback. Turning this off stops automatic requests; you can still request past days from the food log.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if store.dailyFeedbackEnabled {
                        Toggle("Share workout details with agent", isOn: Binding(
                            get: { store.shareWorkoutDetailsWithAgent },
                            set: { setWorkoutSharing($0) }
                        ))
                        .disabled(requestingWorkoutAccess || !health.available)
                        if requestingWorkoutAccess {
                            ProgressView("Requesting workout access…").font(.footnote)
                        }
                        Text("Optional. Shares workout type, time, duration, recorded calories and distance with new daily review requests. Workout calories are already included in active energy. Switching this off stops future uploads of workout details; previously shared reviews remain available.")
                            .font(.footnote).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Review instructions").font(.subheadline.weight(.semibold))
                            TextField("Focus on protein and meal variety. Keep suggestions brief.", text: Binding(
                                get: { store.dailyReviewInstructions },
                                set: { store.setDailyReviewInstructions($0) }
                            ), axis: .vertical)
                                .lineLimit(3...8)
                                .textInputAutocapitalization(.sentences)
                                .accessibilityLabel("Review instructions")
                            Text("\(store.dailyReviewInstructions.utf16.count.formatted()) / 2,000")
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .accessibilityLabel("\(store.dailyReviewInstructions.utf16.count) of 2,000 characters")
                        }
                        Text("Optional. Saved automatically on this iPhone and sent to your agent with each new review request, including requests for past days. Turning reviews off keeps your instructions for later.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Health information") {
                    NavigationLink("Health sources") { HealthSourcesView() }
                }
                Section {
                    Button { showingDeveloper = true } label: {
                        HStack {
                            Text("Version")
                            Spacer()
                            Text("\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showingAgentSetup) { AgentSetupView() }
            .sheet(isPresented: $showingAccount) { AccountView(onSignedOut: { dismiss() }) }
            .sheet(isPresented: $showingProfile) { ProfileView() }
            .sheet(isPresented: $showingDeveloper) { DeveloperView() }
            .task {
                health.configureDietaryExport(accountId: store.accountId)
                do { try await store.refreshConnections(force: true); connectionError = nil }
                catch { connectionError = "Could not check current agent connections. Open setup and refresh to try again." }
            }
            .alert("Could not update settings", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    private func revoke(_ connection: MCPConnection) {
        Task {
            do { try await store.revokeConnection(connection) }
            catch { errorText = error.localizedDescription }
        }
    }

    private func setWorkoutSharing(_ enabled: Bool) {
        guard enabled else { store.setShareWorkoutDetailsWithAgent(false); return }
        guard !requestingWorkoutAccess, let accountId = store.accountId else { return }
        requestingWorkoutAccess = true
        Task {
            defer { requestingWorkoutAccess = false }
            do {
                try await health.requestWorkoutAccess()
                guard store.accountId == accountId, store.dailyFeedbackEnabled else { return }
                // HealthKit doesn't disclose whether read access was declined.
                store.setShareWorkoutDetailsWithAgent(true)
            } catch { errorText = error.localizedDescription }
        }
    }
}

private struct AccountView: View {
    @Environment(FoodStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showingDelete = false
    @State private var confirmingDelete = false
    @State private var errorText: String?
    let onSignedOut: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                if let email = store.accountEmail {
                    Section("Email") { Text(email).foregroundStyle(.secondary) }
                }
                Section {
                    Button("Sign out") {
                        Task {
                            do { try await store.signOut(); onSignedOut() }
                            catch { errorText = error.localizedDescription }
                        }
                    }
                    Button("Delete account and food data", role: .destructive) { confirmingDelete = true }
                }
            }
            .navigationTitle("Your account")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showingDelete) { DeleteAccountView() }
            .confirmationDialog("Delete your account and all food data?", isPresented: $confirmingDelete) {
                Button("Continue to Apple verification", role: .destructive) { showingDelete = true }
            } message: { Text("This removes your profile, foods, logs, estimates, photos, and agent connections.") }
            .alert("Could not update account", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }
}

private struct DeveloperView: View {
    @Environment(FoodStore.self) private var store
    @Environment(HealthEnergy.self) private var health
    @Environment(\.dismiss) private var dismiss
    @Environment(\.foodUnits) private var units
    @AppStorage(OnboardingReplay.requestKey) private var replayOnNextLaunch = false
    @AppStorage(MeasurementPreference.key) private var unitPreference = MeasurementPreference.system.rawValue
    @AppStorage(ForecastCalibration.preferenceKey) private var calibrateForecasts = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Calibrate forecasts from history", isOn: $calibrateForecasts)
                    Link("Research background", destination: URL(string: "https://pubmed.ncbi.nlm.nih.gov/21562087/")!)
                        .font(.footnote).foregroundStyle(.blue)
                    Link("Body-composition energy model", destination: URL(string: "https://www.niddk.nih.gov/-/media/Files/BWP/Hall_Lancet_Web_Appendix.pdf")!)
                        .font(.footnote).foregroundStyle(.blue)
                    Link("Scale accuracy research", destination: URL(string: "https://pmc.ncbi.nlm.nih.gov/articles/PMC8122302/")!)
                        .font(.footnote).foregroundStyle(.blue)
                    if calibrateForecasts {
                        if health.isRefreshingComposition { ProgressView("Reading full body-composition history…") }
                        if let trend = health.compositionTrend {
                            Text("Composition history: \(trend.readings.count) paired days across \(trend.weekCount) weeks, \(trend.firstDate.formatted(date: .abbreviated, time: .omitted)) – \(trend.lastDate.formatted(date: .abbreviated, time: .omitted)).")
                                .font(.footnote).foregroundStyle(.secondary)
                            Text("Fat trend: \(units.weight(-trend.fatChangeKgPerDay * 7)) lost per week. Fat-free mass: \(leanTrendDescription(trend.leanChangeKgPerDay * 7)).")
                                .font(.footnote).foregroundStyle(.secondary)
                            Text("Composition trend influence: \((trend.confidence * 100).formatted(.number.precision(.fractionLength(0))))%")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("No reliable composition trend yet; using Forbes for the fat/fat-free mass split.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if let error = health.compositionHistoryError {
                            Text("Full composition history could not be refreshed: \(error)")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if let calibration = health.forecastCalibration(using: store) {
                            Text("Using \(calibration.energyDays) food + Health days and \(calibration.weightDays) weight days across \(calibration.weightWeeks) weeks.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Text(calibration.adjustmentDescription)
                                .font(.footnote).foregroundStyle(.secondary)
                            if let profile = store.profile,
                               let percent = calibration.projectionDeficitPercent(for: health.representativeBudget(for: profile)) {
                                Text("Selected pace: \(profile.deficitPercent)% deficit")
                                    .font(.footnote).foregroundStyle(.secondary)
                                Text("Forecast at selected pace: \(percent.formatted(.number.precision(.fractionLength(1))))% deficit")
                                    .font(.footnote).foregroundStyle(.secondary)
                                ForecastDiagnosticsView(profile: profile, calibration: calibration)
                            }
                        } else {
                            Text("Using the standard energy gap until enough consistent food and Health history is available.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Forecasts") } footer: {
                    Text("Experimental, off by default and local to this iPhone. Changes only forecast curves, body-fat projections and estimated dates. Calorie allowances, your pace and logged totals never change. The forecast-implied percentage divides the forecast gap by your unchanged calorie allowance plus that gap. It describes the percentage implied by the curve, not a measurement of true TDEE.\n\nUses up to 42 completed days, with at least 28 days of history, food + paired resting/active Health energy on 90% of days, and 14 weight days across at least four weekly groups. Weekly medians and a robust trend fit compare observed weight change with the change implied by recorded energy balance. The few missing energy days use the recorded average. Corrections are capped at ±1,000 kcal/day before damping, with no separate percentage-of-TDEE cap, and damped with shorter, sparser or noisier history. The raw mismatch shown above is uncapped. Missing, stale or very noisy history uses the standard forecast. Projections flatten if the adjusted gap is zero or negative; weight gain is not modeled.\n\nThe composition split uses all readable paired weight/body-fat dates, including dates before you joined 00Food. It uses weekly medians and a robust fit with a 90-day recency half-life; older dates remain in the fit. At least 14 paired days, four weekly groups and a 28-day span are needed, with a paired reading in the last seven days. Noisy/sparse history pulls the split toward Forbes. The learned ratio is bounded between gaining 1 kg and losing 3 kg of fat-free mass per kg of fat lost; this is an experimental guardrail, not a physiological limit. The personal split gradually returns toward Forbes as projected fat mass leaves the current range. Paired recent composition data also improves the energy fit using about 9,440 kcal/kg fat and 1,816 kcal/kg fat-free mass; otherwise the existing weight-based energy fit remains. A stable scale with falling fat can therefore be recognized as recomposition. This does not establish that exercise caused muscle preservation: fat-free mass also includes water and other tissue. Negative fat-free mass change in the existing forecast summary means a modeled gain. All history stays on this device.\n\nThese are experimental app heuristics, not a validated physiological model. Missing food logs and water changes can still distort estimates. Existing chart labels and explanations describe the standard model; this Developer option is the only explanation of the calibration.")
                }
                Section {
                    Picker("Measurement system", selection: $unitPreference) {
                        ForEach(MeasurementPreference.allCases, id: \.rawValue) { preference in
                            Text(preference.title).tag(preference.rawValue)
                        }
                    }
                } header: { Text("Units") } footer: {
                    Text("Follow iPhone uses its Measurement System setting. US uses pounds, feet/inches, and US fluid ounces; UK uses imperial fluid ounces. The override also applies to your Watch. Calorie values and the amount logged by each water glass stay the same.")
                }
                Section {
                    Toggle("Replay onboarding on next launch", isOn: $replayOnNextLaunch)
                } header: { Text("Onboarding") } footer: {
                    Text("Close and reopen 00Food to see the welcome and Health explanation again. Your food logs and selected plan are kept. You can review and save your details or cancel. The switch resets after launch.")
                }
                Section("Apple Health") {
                    Button("Refresh Health data") {
                        Task {
                            if health.requested { await health.refresh() }
                            else { await health.connect() }
                        }
                    }
                    DelayedNotice(message: health.errorMessage, isRefreshing: health.isRefreshing) { error in
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }

            }
            .navigationTitle("Developer")
            .task(id: calibrateForecasts) {
                if calibrateForecasts { await health.refreshCompositionHistory() }
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func leanTrendDescription(_ kgPerWeek: Double) -> String {
        if abs(kgPerWeek) < 0.05 { return "approximately stable" }
        return "\(units.weight(abs(kgPerWeek))) \(kgPerWeek < 0 ? "lost" : "gained") per week"
    }
}

struct ManualWeightView: View {
    @Environment(FoodStore.self) private var store
    @Environment(HealthEnergy.self) private var health
    @Environment(\.dismiss) private var dismiss
    @Environment(\.foodUnits) private var units
    @State private var weightKg: Double? = 70.0
    @State private var busy = false
    @State private var errorText: String?
    var onLogged: (Double) -> Void = { _ in }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Weight")
                        Spacer()
                        WeightInput(kilograms: $weightKg)
                    }
                } footer: {
                    Text("Saves today's weight to Apple Health and updates the weight used by your 00Food target. It will appear in your progress chart.")
                }
            }
            .navigationTitle("Log weight")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Log") { save() }
                        .disabled(busy || (weightKg.map { !$0.isFinite || !(25...400).contains($0) } ?? true))
                }
            }
            .onAppear { weightKg = health.usableLatestWeightKg ?? store.profile?.weightKg ?? 70 }
            .alert("Could not log weight", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    private func save() {
        guard !busy, let weightKg else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await health.logWeight(weightKg)
                if var profile = store.profile {
                    profile.weightKg = weightKg
                    try await store.saveProfile(profile)
                }
                onLogged(weightKg)
                dismiss()
            } catch { errorText = error.localizedDescription }
        }
    }
}
