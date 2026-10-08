import SwiftUI

struct ProfileView: View {
    @Environment(FoodStore.self) private var store
    @Environment(HealthEnergy.self) private var health
    @Environment(\.dismiss) private var dismiss
    @AppStorage("activeDayStartMinutes") private var storedActiveDayStartMinutes = 7 * 60
    @AppStorage("activeDayEndMinutes") private var storedActiveDayEndMinutes = 23 * 60
    var isOnboarding: Bool = false
    @State private var heightCm = 170.0
    @State private var savedWeightKg: Double?
    @State private var estimateProfile = "neutral"
    @State private var deficitKcal = 300
    @State private var birthYear = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var showingManualWeight = false
    @State private var activeDayStartMinutes = 7 * 60
    @State private var activeDayEndMinutes = 23 * 60

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Height")
                        Spacer()
                        TextField("cm", value: $heightCm, format: .number.precision(.fractionLength(0)))
                            .multilineTextAlignment(.trailing).keyboardType(.decimalPad)
                            .accessibilityLabel("Height in centimeters")
                        Text("cm").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Weight")
                        Spacer()
                        Text(recordedWeightKg.map { "\($0.formatted(.number.precision(.fractionLength(1)))) kg" } ?? "Not recorded")
                            .foregroundStyle(.secondary)
                    }
                    Button("Log weight manually") { showingManualWeight = true }
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
                            .accessibilityLabel("Birth year, optional")
                    }
                    HStack {
                        Text("Resting estimate")
                        Spacer()
                        Text(recordedWeightKg == nil ? "Add weight first" : "\(preview.restingKcal) kcal/day")
                            .foregroundStyle(.secondary)
                        InfoDisclosure(title: "Resting estimate from your details", message: restingExplanation)
                    }
                } header: { Text("Your details") } footer: {
                    Text("Birth year improves the fallback resting estimate. Leave it empty to use age 35 as a reference.")
                }
                Section {
                    HStack {
                        Text("Resting energy")
                        Spacer()
                        Text(health.restingAverageKcal.map { "\($0) kcal/day" } ?? "Not enough data")
                            .foregroundStyle(.secondary)
                        InfoDisclosure(title: "Resting energy", message: restingExplanation)
                    }
                    HStack {
                        Text("Active energy today")
                        Spacer()
                        Text("\(health.activeKcal) kcal").foregroundStyle(.secondary)
                    }
                    if !health.requested || !health.weightRequested {
                        Button("Connect Apple Health") {
                            Task { await health.connect() }
                        }
                    }
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
                    Text("00Food uses your latest recorded weight. Saving these details also saves that weight in your 00Food profile. Logging weight manually updates Apple Health and your profile; water entries stay in Apple Health. Other Health history stays on this device unless you request Daily feedback.")
                }
                Section {
                    DatePicker("Start", selection: startTime, displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: endTime, displayedComponents: .hourAndMinute)
                } header: {
                    Text("Active day")
                } footer: {
                    Text("Sets the active-day marker on the home screen. The food marker uses your current allowance, including Health active energy so far.")
                }
                if isOnboarding {
                    Section {
                        Button("Start logging") { save() }
                            .frame(maxWidth: .infinity).disabled(busy || !valid)
                    }
                }
            }
            .navigationTitle(isOnboarding ? "Set up 00Food" : "Your details")
            .toolbar {
                if !isOnboarding {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { save() }
                            .fontWeight(.semibold)
                            .disabled(busy || !valid)
                    }
                }
            }
            .onAppear {
                activeDayStartMinutes = storedActiveDayStartMinutes
                activeDayEndMinutes = storedActiveDayEndMinutes
                if let profile = store.profile {
                    heightCm = profile.heightCm
                    savedWeightKg = profile.weightKg
                    estimateProfile = profile.estimateProfile
                    deficitKcal = profile.deficitKcal
                    birthYear = profile.birthYear.map(String.init) ?? ""
                }
            }
            .task {
                health.setHistoryStart(store.accountStartedAt)
                await health.refresh()
            }
            .sheet(isPresented: $showingManualWeight) {
                ManualWeightView { savedWeightKg = $0 }
            }
            .alert("Could not save details", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    private var valid: Bool {
        let year = birthYear.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentYear = Calendar.current.component(.year, from: Date())
        return (100...250).contains(heightCm) && recordedWeightKg != nil &&
            (year.isEmpty || (Int(year).map { (1900...(currentYear - 18)).contains($0) } ?? false))
    }
    private var preview: FoodProfile {
        FoodProfile(heightCm: heightCm, weightKg: recordedWeightKg ?? 70,
                    estimateProfile: estimateProfile, deficitKcal: deficitKcal,
                    birthYear: Int(birthYear.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private var recordedWeightKg: Double? { health.usableLatestWeightKg ?? savedWeightKg }

    private var restingExplanation: String {
        let introduction = "When available, your target uses recent Apple Health resting energy. Otherwise it uses a directional estimate from your details and latest recorded weight. It does not account for health conditions or body composition."
        if let average = health.restingAverageKcal, recordedWeightKg != nil {
            let difference = average - preview.restingKcal
            return introduction + "\n\nThe Health average is \(difference >= 0 ? "+" : "")\(difference) kcal/day compared with your details estimate, based on \(health.restingDaysUsed) of the last 7 completed days."
        }
        return introduction + "\n\nThe Health average needs at least 5 of the last 7 completed days with readable resting energy (currently \(health.restingDaysUsed)). Birth year improves the details estimate; without it, age 35 is used as a reference."
    }

    private var startTime: Binding<Date> {
        Binding(get: { Self.today(at: activeDayStartMinutes) },
                set: { activeDayStartMinutes = Self.minutes(in: $0) })
    }

    private var endTime: Binding<Date> {
        Binding(get: { Self.today(at: activeDayEndMinutes) },
                set: { activeDayEndMinutes = Self.minutes(in: $0) })
    }

    private static func today(at minutes: Int) -> Date {
        Calendar.current.date(byAdding: .minute, value: minutes,
                              to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }

    private static func minutes(in date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
    private func save() {
        guard !busy, valid else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await store.saveProfile(preview)
                storedActiveDayStartMinutes = activeDayStartMinutes
                storedActiveDayEndMinutes = activeDayEndMinutes
                if !isOnboarding { dismiss() }
            } catch { errorText = error.localizedDescription }
        }
    }
}
