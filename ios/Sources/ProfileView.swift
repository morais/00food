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
    @State private var birthYear = ""
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
                    HStack {
                        Text("Birth year")
                        Spacer()
                        TextField("Optional", text: $birthYear)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                } header: { Text("Your details") } footer: {
                    Text("Birth year improves the fallback resting estimate. Leave it empty to use age 35 as a reference.")
                }
                Section("Daily target") {
                    Picker("Calorie gap", selection: $deficitKcal) {
                        ForEach(DeficitLevel.allCases) { level in
                            Text("\(level.title) · \(level.rawValue) kcal/day").tag(level.rawValue)
                        }
                    }
                    Text("Resting estimate \(health.effectiveRestingKcal(for: preview)) − calorie gap = \(preview.target(for: deficitKcal, resting: health.effectiveRestingKcal(for: preview))) kcal/day, plus Apple Health active energy.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("The minimum food target is 1,200 kcal. The actual gap may be smaller at that floor.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    if let weight = health.latestWeightKg, let date = health.latestWeightDate {
                        Button("Use latest weight: \(weight.formatted(.number.precision(.fractionLength(1)))) kg") {
                            if (25...400).contains(weight) { weightKg = weight }
                            else { errorText = "The Health weight is outside the supported range." }
                        }
                        Text("Recorded \(date.formatted(date: .abbreviated, time: .omitted)). You can edit the weight above before continuing.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Button(health.weightRequested ? "Refresh Apple Health weight" : "Connect Apple Health and get weight") {
                            Task { if health.weightRequested { await health.refresh() } else { await health.connect() } }
                        }
                        if health.weightRequested {
                            Text("No readable weight entry was found. You can enter your weight above.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if let error = health.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                } header: { Text("Apple Health") } footer: {
                    Text("00Food reads weight, body fat, and active and resting energy. A weight you choose to use is saved in your 00Food profile. Health history stays on this device unless you request Daily feedback.")
                }
                if isOnboarding {
                    Section {
                        Button("Start logging") { save() }
                            .frame(maxWidth: .infinity).disabled(busy || !valid)
                    }
                }
                Section {
                    Text("When available, your target uses recent Apple Health resting energy. Otherwise it uses a directional estimate from your details. It does not account for health conditions or body composition.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(isOnboarding ? "Set up 00Food" : "Your details")
            .toolbar {
                if !isOnboarding {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                            .disabled(busy)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { save() }
                            .fontWeight(.semibold)
                            .disabled(busy || !valid)
                    }
                }
            }
            .onAppear {
                if let profile = store.profile {
                    heightCm = profile.heightCm
                    weightKg = profile.weightKg
                    estimateProfile = profile.estimateProfile
                    deficitKcal = DeficitLevel.nearest(to: profile.deficitKcal).rawValue
                    birthYear = profile.birthYear.map(String.init) ?? ""
                }
            }
            .task {
                health.setHistoryStart(store.accountStartedAt)
                if health.requested { await health.refresh() }
            }
            .alert("Could not save details", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    private var valid: Bool {
        let year = birthYear.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentYear = Calendar.current.component(.year, from: Date())
        return (100...250).contains(heightCm) && (25...400).contains(weightKg) &&
            (year.isEmpty || (Int(year).map { (1900...(currentYear - 18)).contains($0) } ?? false))
    }
    private var preview: FoodProfile {
        FoodProfile(heightCm: heightCm, weightKg: weightKg,
                    estimateProfile: estimateProfile, deficitKcal: deficitKcal,
                    birthYear: Int(birthYear.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    private func save() {
        guard !busy, valid else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await store.saveProfile(preview)
                if !isOnboarding { dismiss() }
            } catch { errorText = error.localizedDescription }
        }
    }
}
