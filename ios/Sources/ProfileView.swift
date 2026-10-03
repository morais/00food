import SwiftUI

struct ProfileView: View {
    @Environment(FoodStore.self) private var store
    @Environment(HealthEnergy.self) private var health
    @Environment(\.dismiss) private var dismiss
    var isOnboarding: Bool = false
    @State private var heightCm = 170.0
    @State private var weightKg = 70.0
    @State private var estimateProfile = "neutral"
    @State private var deficitKcal = 300
    @State private var connectHealth = true
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Height")
                        Spacer()
                        TextField("cm", value: $heightCm, format: .number.precision(.fractionLength(0)))
                            .multilineTextAlignment(.trailing).keyboardType(.decimalPad)
                        Text("cm").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Weight")
                        Spacer()
                        TextField("kg", value: $weightKg, format: .number.precision(.fractionLength(1)))
                            .multilineTextAlignment(.trailing).keyboardType(.decimalPad)
                        Text("kg").foregroundStyle(.secondary)
                    }
                    Picker("Estimate setting", selection: $estimateProfile) {
                        Text("Neutral").tag("neutral")
                        Text("Female").tag("female")
                        Text("Male").tag("male")
                    }
                } header: { Text("Your details") } footer: {
                    Text("Used only for a rough calorie target. Choose the estimate setting that works for you.")
                }
                Section("Daily target") {
                    Stepper("Weight-loss adjustment: \(deficitKcal) kcal", value: $deficitKcal, in: 0...1000, step: 50)
                    Text("Rough baseline: \(preview.roughDailyTarget) kcal/day before Apple Health active energy.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if isOnboarding {
                    Section {
                        Toggle("Connect Apple Health", isOn: $connectHealth)
                    } footer: {
                        Text("Only active energy is read. It stays on this device and adds to the daily allowance.")
                    }
                }
                Section {
                    Button(isOnboarding ? "Start logging" : "Save details") { save() }
                        .frame(maxWidth: .infinity).disabled(busy || !valid)
                }
                Section {
                    Text("This is a directional estimate from height, weight, and the selected setting. It does not account for age, health conditions, or body composition.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(isOnboarding ? "Set up 00Food" : "Your details")
            .toolbar {
                if !isOnboarding { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            }
            .onAppear {
                if let profile = store.profile {
                    heightCm = profile.heightCm
                    weightKg = profile.weightKg
                    estimateProfile = profile.estimateProfile
                    deficitKcal = profile.deficitKcal
                }
            }
            .alert("Could not save details", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    private var valid: Bool { (100...250).contains(heightCm) && (25...400).contains(weightKg) }
    private var preview: FoodProfile {
        FoodProfile(heightCm: heightCm, weightKg: weightKg,
                    estimateProfile: estimateProfile, deficitKcal: deficitKcal)
    }
    private func save() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await store.saveProfile(preview)
                if isOnboarding && connectHealth { await health.connect() }
                if !isOnboarding { dismiss() }
            } catch { errorText = error.localizedDescription }
        }
    }
}
