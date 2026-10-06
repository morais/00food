import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(FoodStore.self) private var store
    @Environment(HealthEnergy.self) private var health
    @Environment(\.dismiss) private var dismiss
    @AppStorage("activeDayStartMinutes") private var activeDayStartMinutes = 7 * 60
    @AppStorage("activeDayEndMinutes") private var activeDayEndMinutes = 23 * 60
    @State private var showingProfile = false
    @State private var showingManualWeight = false
    @State private var showingDelete = false
    @State private var confirmingDelete = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if let email = store.accountEmail { Text(email).foregroundStyle(.secondary) }
                    Button("Your details & target") { showingProfile = true }
                    Button("Sign out") {
                        Task {
                            do { try await store.signOut(); dismiss() }
                            catch { errorText = error.localizedDescription }
                        }
                    }
                    Button("Delete account and food data", role: .destructive) { confirmingDelete = true }
                }
                Section("Apple Health") {
                    if let profile = store.profile {
                        HStack {
                            Text("Resting energy · Health")
                            Spacer()
                            Text(health.restingAverageKcal.map { "\($0) kcal/day" } ?? "Not enough data")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Resting estimate · details")
                            Spacer()
                            Text("\(profile.restingKcal) kcal/day").foregroundStyle(.secondary)
                        }
                        if let average = health.restingAverageKcal {
                            let difference = average - profile.restingKcal
                            Text("Your food target uses the Health average: \(difference >= 0 ? "+" : "")\(difference) kcal/day compared with the estimate from your details. Based on \(health.restingDaysUsed) of the last 7 completed days.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("Your food target uses the estimate from your details until at least 5 of the last 7 completed days have readable resting energy (currently \(health.restingDaysUsed)).")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("Active energy today")
                        Spacer()
                        Text("\(health.activeKcal) kcal").foregroundStyle(.secondary)
                    }
                    if let weight = health.latestWeightKg {
                        HStack {
                            Text("Latest recorded weight")
                            Spacer()
                            Text("\(weight.formatted(.number.precision(.fractionLength(1)))) kg")
                                .foregroundStyle(.secondary)
                        }
                        Text("Open Your details & target to use this weight in your daily target.")
                            .font(.footnote).foregroundStyle(.secondary)
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
                    Button(health.bodyFatRequested ? "Refresh Health data" : "Connect Apple Health") {
                        Task {
                            if health.bodyFatRequested { await health.refresh() }
                            else { await health.connect() }
                        }
                    }
                    if let accountId = store.accountId {
                        if health.dietaryExportEnabled && health.dietaryExportAuthorized {
                            Label("Dietary Energy export is on", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Button("Write new food logs to Apple Health") {
                                Task { await health.enableDietaryExport(accountId: accountId, logs: store.logs) }
                            }
                        }
                        Text("After you enable export, new 00Food logs are written as Dietary Energy. Deleting a log removes its matching Health entry. Earlier logs are not exported.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error = health.dietaryErrorMessage {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    if let error = health.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
                    Text("Health history stays on this device. Logging weight manually also updates your 00Food profile weight; water stays in Apple Health.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Active day") {
                    DatePicker("Start", selection: startTime, displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: endTime, displayedComponents: .hourAndMinute)
                    Text("Sets the time marker on Today's rough balance. The food marker uses your current allowance, including Health active energy so far.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("AI agent connection") {
                    Text("Remote MCP address").font(.caption).foregroundStyle(.secondary)
                    Text(store.mcpAddress).font(.footnote).textSelection(.enabled)
                    Button("Copy MCP address") { UIPasteboard.general.string = store.mcpAddress }
                    Text("Add this address in your AI client’s remote MCP settings, then sign in with the same Apple account. Ask the agent to list pending foods, inspect any photo, and propose an estimate.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if store.connections.isEmpty { Text("No connected agents yet.").foregroundStyle(.secondary) }
                    ForEach(store.connections) { connection in
                        HStack {
                            Text(connection.clientName)
                            Spacer()
                            Button("Revoke", role: .destructive) { revoke(connection) }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showingProfile) { ProfileView() }
            .sheet(isPresented: $showingManualWeight) { ManualWeightView() }
            .sheet(isPresented: $showingDelete) { DeleteAccountView() }
            .confirmationDialog("Delete your account and all food data?", isPresented: $confirmingDelete) {
                Button("Continue to Apple verification", role: .destructive) { showingDelete = true }
            } message: { Text("This removes your profile, foods, logs, estimates, photos, and agent connections.") }
            .task {
                health.configureDietaryExport(accountId: store.accountId)
                try? await store.refreshConnections()
            }
            .alert("Could not update settings", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    private var startTime: Binding<Date> {
        Binding(
            get: { Self.today(at: activeDayStartMinutes) },
            set: { activeDayStartMinutes = Self.minutes(in: $0) }
        )
    }

    private var endTime: Binding<Date> {
        Binding(
            get: { Self.today(at: activeDayEndMinutes) },
            set: { activeDayEndMinutes = Self.minutes(in: $0) }
        )
    }

    private static func today(at minutes: Int) -> Date {
        Calendar.current.date(byAdding: .minute, value: minutes,
                              to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }

    private static func minutes(in date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private func revoke(_ connection: MCPConnection) {
        Task {
            do { try await store.revokeConnection(connection) }
            catch { errorText = error.localizedDescription }
        }
    }
}

private struct ManualWeightView: View {
    @Environment(FoodStore.self) private var store
    @Environment(HealthEnergy.self) private var health
    @Environment(\.dismiss) private var dismiss
    @State private var weightKg = 70.0
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Weight")
                        Spacer()
                        TextField("kg", value: $weightKg, format: .number.precision(.fractionLength(1)))
                            .multilineTextAlignment(.trailing).keyboardType(.decimalPad)
                        Text("kg").foregroundStyle(.secondary)
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
                        .disabled(busy || !weightKg.isFinite || !(25...400).contains(weightKg))
                }
            }
            .onAppear { weightKg = health.latestWeightKg ?? store.profile?.weightKg ?? 70 }
            .alert("Could not log weight", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    private func save() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await health.logWeight(weightKg)
                if var profile = store.profile {
                    profile.weightKg = weightKg
                    try await store.saveProfile(profile)
                }
                dismiss()
            } catch { errorText = error.localizedDescription }
        }
    }
}
