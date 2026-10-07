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
    @State private var showingManualWeight = false

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
                Section {
                    HStack {
                        Text("Resting energy · Health")
                        Spacer()
                        Text(health.restingAverageKcal.map { "\($0) kcal/day" } ?? "Not enough data")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Resting estimate · details")
                        Spacer()
                        Text("\(preview.restingKcal) kcal/day").foregroundStyle(.secondary)
                    }
                    if let average = health.restingAverageKcal {
                        let difference = average - preview.restingKcal
                        Text("Your food target uses the Health average: \(difference >= 0 ? "+" : "")\(difference) kcal/day compared with the estimate from your details. Based on \(health.restingDaysUsed) of the last 7 completed days.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Your food target uses the estimate from your details until at least 5 of the last 7 completed days have readable resting energy (currently \(health.restingDaysUsed)).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Active energy today")
                        Spacer()
                        Text("\(health.activeKcal) kcal").foregroundStyle(.secondary)
                    }
                    if let weight = health.latestWeightKg, let date = health.latestWeightDate {
                        HStack {
                            Text("Latest recorded weight")
                            Spacer()
                            Text("\(weight.formatted(.number.precision(.fractionLength(1)))) kg")
                                .foregroundStyle(.secondary)
                        }
                        Button("Use latest weight: \(weight.formatted(.number.precision(.fractionLength(1)))) kg") {
                            if (25...400).contains(weight) { weightKg = weight }
                            else { errorText = "The Health weight is outside the supported range." }
                        }
                        Text("Recorded \(date.formatted(date: .abbreviated, time: .omitted)). You can edit the weight above before continuing.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        if !health.weightRequested {
                            Button("Connect Apple Health and get weight") {
                                Task { await health.connect() }
                            }
                        }
                        if health.weightRequested {
                            Text("No readable weight entry was found. You can enter your weight above.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Button("Log weight manually") { showingManualWeight = true }
                    if let fat = health.latestBodyFatPercent {
                        HStack {
                            Text("Latest body fat")
                            Spacer()
                            Text("\(fat.formatted(.number.precision(.fractionLength(1))))%")
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("Water today")
                        Spacer()
                        Text("\(health.waterMlToday.formatted()) mL").foregroundStyle(.secondary)
                    }
                    if let error = health.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                } header: { Text("Apple Health") } footer: {
                    Text("00Food reads weight, body fat, water, and active and resting energy. Logging weight manually also updates your 00Food profile; water entries stay in Apple Health. Health history stays on this device unless you request Daily feedback.")
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
                    deficitKcal = profile.deficitKcal
                    birthYear = profile.birthYear.map(String.init) ?? ""
                }
            }
            .task {
                health.setHistoryStart(store.accountStartedAt)
                if health.requested { await health.refresh() }
            }
            .sheet(isPresented: $showingManualWeight) {
                ManualWeightView { weightKg = $0 }
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
