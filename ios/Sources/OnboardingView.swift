import SwiftUI

struct OnboardingView: View {
    @Environment(FoodStore.self) private var store
    @Environment(HealthEnergy.self) private var health
    @State private var showingDetails = false
    @State private var connecting = false

    var body: some View {
        if showingDetails {
            OnboardingDetailsView(onBack: { showingDetails = false })
        } else {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Let your tracker do the measuring.").font(.title2.bold())
                        Text("00Food works best with Apple Watch or another tracker that syncs energy to Apple Health. You choose which readings to share.")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 16) {
                            permission("Active energy", icon: "figure.walk",
                                detail: "Adds the energy from your movement to today's calorie allowance.")
                            permission("Resting energy", icon: "heart.fill",
                                detail: "Uses recent completed days to estimate your baseline calorie budget.")
                            permission("Weight", icon: "scalemass",
                                detail: "Uses your latest reading for progress and a fallback estimate when resting energy isn't available.")
                            permission("Body fat", icon: "chart.xyaxis.line",
                                detail: "Adds body-fat readings to your progress chart. This is optional.")
                            permission("Water", icon: "drop.fill",
                                detail: "Shows your recorded water intake and progress toward your daily goal.")
                        }
                        Text("The next sheet asks to read these values. Writing water is requested when you log a glass; writing weight when you log it to Health. Writing food calories is an optional setting.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("Your details and latest weight are saved to your account. Other Health history stays on this device unless you request a daily review.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let error = health.errorMessage {
                            Text(error).font(.footnote).foregroundStyle(.orange)
                        }
                        Button {
                            connecting = true
                            Task {
                                await health.connect()
                                connecting = false
                                if health.errorMessage == nil { showingDetails = true }
                            }
                        } label: {
                            HStack {
                                Spacer()
                                if connecting { ProgressView().tint(.white) }
                                Text(connecting ? "Connecting…" : "Connect Apple Health").fontWeight(.semibold)
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(connecting || !health.available)
                        Button("Continue without Health") { showingDetails = true }
                            .frame(maxWidth: .infinity).disabled(connecting)
                    }
                    .padding(20)
                }
                .navigationTitle("Welcome to 00Food")
                .navigationBarTitleDisplayMode(.inline)
                .onAppear { health.setHistoryStart(store.accountStartedAt) }
            }
        }
    }

    private func permission(_ title: String, icon: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(.blue).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

private struct OnboardingDetailsView: View {
    let onBack: () -> Void
    @Environment(FoodStore.self) private var store
    @Environment(HealthEnergy.self) private var health
    @State private var height = ""
    @State private var weight = ""
    @State private var estimateProfile = "neutral"
    @State private var saving = false
    @State private var errorText: String?

    private var heightCm: Double? { Self.number(height) }
    private var weightKg: Double? { health.usableLatestWeightKg ?? Self.number(weight) }
    private var valid: Bool {
        guard let heightCm, let weightKg else { return false }
        return (100...250).contains(heightCm) && (25...400).contains(weightKg)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Height in cm", text: $height).keyboardType(.decimalPad)
                } header: { Text("Height") } footer: {
                    Text("Used for your BMI progress range and the fallback resting estimate.")
                }
                Section {
                    if let recorded = health.usableLatestWeightKg {
                        LabeledContent("From Apple Health", value: "\(recorded.formatted(.number.precision(.fractionLength(1)))) kg")
                    } else {
                        TextField("Weight in kg", text: $weight).keyboardType(.decimalPad)
                    }
                } header: { Text("Weight") } footer: {
                    Text(health.usableLatestWeightKg == nil
                         ? "We need a weight for the fallback estimate. This value is saved to your account; you can connect a scale or log a Health weight later."
                         : "We'll use your latest recorded weight for progress and the fallback estimate.")
                }
                Section {
                    Picker("Estimate setting", selection: $estimateProfile) {
                        Text("Neutral").tag("neutral")
                        Text("Female").tag("female")
                        Text("Male").tag("male")
                    }
                } header: { Text("Optional") } footer: {
                    Text("Adjusts the fallback estimate and body-fat reference lines. You can keep Neutral or change this later.")
                }
                Section {
                    Text("Your budget uses Health resting energy when enough history is available. The fallback uses a reference age of 35. Choose your calorie plan later in Progress & plans.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button { save() } label: {
                        HStack {
                            Spacer()
                            if saving { ProgressView() }
                            Text("Start logging").fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent).disabled(saving || !valid)
                }
            }
            .navigationTitle("Just the essentials")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", action: onBack).disabled(saving)
                }
            }
            .alert("Could not save details", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    private static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }

    private func save() {
        guard valid, !saving, let heightCm, let weightKg else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await store.saveProfile(FoodProfile(heightCm: heightCm, weightKg: weightKg,
                    estimateProfile: estimateProfile, deficitKcal: DeficitLevel.gentle.rawValue))
            } catch { errorText = error.localizedDescription }
        }
    }
}
