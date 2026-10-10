import SwiftUI
import UIKit

struct ProfileView: View {
    @Environment(FoodStore.self) private var store
    @Environment(HealthEnergy.self) private var health
    @Environment(\.dismiss) private var dismiss
    @AppStorage("activeDayStartMinutes") private var storedActiveDayStartMinutes = 7 * 60
    @AppStorage("activeDayEndMinutes") private var storedActiveDayEndMinutes = 23 * 60
    @State private var heightCm = 170.0
    @State private var savedWeightKg: Double?
    @State private var estimateProfile = "neutral"
    @State private var showingPacePicker = false
    @State private var selectedDeficitPercent = DeficitLevel.gentle.rawValue
    @State private var busy = false
    @State private var errorText: String?
    @State private var showingManualWeight = false
    @State private var showingHealthPermissions = false
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
                        Text("Resting estimate")
                        Spacer()
                        Text(recordedWeightKg == nil ? "Add weight first" : "\(preview.restingKcal) kcal/day")
                            .foregroundStyle(.secondary)
                        InfoDisclosure(title: "Resting estimate from your details", message: restingExplanation)
                    }
                } header: { Text("Your details") }
                Section {
                    Button {
                        selectedDeficitPercent = currentDeficitPercent
                        showingPacePicker = true
                    } label: {
                        HStack {
                            Text("Plan")
                            Spacer()
                            Text("\(DeficitLevel(rawValue: currentDeficitPercent)?.title ?? "Custom") · \(currentDeficitPercent)%")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain).disabled(busy || !valid)
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
                    if health.needsPermissionRequest {
                        Button("Request remaining permissions") {
                            Task { await health.requestRemainingPermissions() }
                        }
                        .disabled(health.requestingPermissions)
                    }
                    Button("Review Health permissions") { showingHealthPermissions = true }
                        .disabled(!health.available)
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
                    DelayedNotice(message: health.errorMessage, isRefreshing: health.isRefreshing) { error in
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    if health.dietaryWriteAuthorized {
                        DelayedNotice(message: health.dietaryErrorMessage, isRefreshing: health.isRefreshing) { error in
                            Text(error).font(.footnote).foregroundStyle(.orange)
                        }
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
            }
            .navigationTitle("Your details")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { save() }
                        .fontWeight(.semibold)
                        .disabled(busy || !valid)
                }
            }
            .onAppear {
                activeDayStartMinutes = storedActiveDayStartMinutes
                activeDayEndMinutes = storedActiveDayEndMinutes
                if let profile = store.profile {
                    heightCm = profile.heightCm
                    savedWeightKg = profile.weightKg
                    estimateProfile = profile.estimateProfile
                }
            }
            .task {
                health.setHistoryStart(store.accountStartedAt)
                await health.refresh()
            }
            .sheet(isPresented: $showingPacePicker) {
                PaceSelectionView(profile: preview, deficitPercent: $selectedDeficitPercent,
                                  firstDay: store.accountStartedAt ?? Calendar.current.startOfDay(for: Date()),
                                  saveTitle: "Save plan", onCancel: { showingPacePicker = false }) { updated in
                    // Save only the plan here; other form edits wait for Done.
                    var saved = store.profile ?? updated
                    saved.deficitPercent = updated.deficitPercent
                    try await store.saveProfile(saved)
                    showingPacePicker = false
                }
            }
            .sheet(isPresented: $showingManualWeight) {
                ManualWeightView { savedWeightKg = $0 }
            }
            .alert("Health permissions", isPresented: $showingHealthPermissions) {
                Button("Open Health") {
                    UIApplication.shared.open(URL(string: "x-apple-health://")!)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("In Health, tap your profile picture → Privacy → Apps → 00Food to change read and write access. Apple does not tell apps which read permissions were declined, so you can review them here even when no missing permission is detected.")
            }
            .alert("Could not save details", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    private var valid: Bool {
        (100...250).contains(heightCm) && recordedWeightKg != nil
    }
    private var currentDeficitPercent: Int { store.profile?.deficitPercent ?? DeficitLevel.gentle.rawValue }
    private var preview: FoodProfile {
        FoodProfile(heightCm: heightCm, weightKg: recordedWeightKg ?? 70,
                    estimateProfile: estimateProfile, deficitPercent: currentDeficitPercent)
    }

    private var recordedWeightKg: Double? { health.usableLatestWeightKg ?? savedWeightKg }

    private var restingExplanation: String {
        let introduction = "Your allowance is (resting + active energy) × (1 − your plan’s deficit percentage). When available, the full-day resting estimate uses recent Apple Health resting energy. Active energy so far is included before the percentage is applied. Otherwise it uses a directional estimate from your details and latest recorded weight, using a reference age of 35. It does not account for health conditions or body composition."
        if let average = health.restingAverageKcal, recordedWeightKg != nil {
            let difference = average - preview.restingKcal
            return introduction + "\n\nThe Health average is \(difference >= 0 ? "+" : "")\(difference) kcal/day compared with your details estimate, based on \(health.restingDaysUsed) of the last 7 completed days."
        }
        return introduction + "\n\nThe Health average needs at least 5 of the last 7 completed days with readable resting energy (currently \(health.restingDaysUsed))."
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
                dismiss()
            } catch { errorText = error.localizedDescription }
        }
    }
}
