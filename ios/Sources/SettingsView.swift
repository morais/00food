import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(FoodStore.self) private var store
    @Environment(HealthEnergy.self) private var health
    @Environment(\.dismiss) private var dismiss
    @State private var showingProfile = false
    @State private var showingDeveloper = false
    @State private var showingDelete = false
    @State private var confirmingDelete = false
    @State private var errorText: String?
    @State private var showingAgentSetup = false
    @State private var connectionError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if let email = store.accountEmail { Text(email).foregroundStyle(.secondary) }
                    Button("Your details & Health") { showingProfile = true }
                    Button("Sign out") {
                        Task {
                            do { try await store.signOut(); dismiss() }
                            catch { errorText = error.localizedDescription }
                        }
                    }
                    Button("Delete account and food data", role: .destructive) { confirmingDelete = true }
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
                }
                Section {
                    Button { showingDeveloper = true } label: {
                        HStack {
                            Text("Version")
                            Spacer()
                            Text("\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showingAgentSetup) { AgentSetupView() }
            .sheet(isPresented: $showingProfile) { ProfileView() }
            .sheet(isPresented: $showingDeveloper) { DeveloperView() }
            .sheet(isPresented: $showingDelete) { DeleteAccountView() }
            .confirmationDialog("Delete your account and all food data?", isPresented: $confirmingDelete) {
                Button("Continue to Apple verification", role: .destructive) { showingDelete = true }
            } message: { Text("This removes your profile, foods, logs, estimates, photos, and agent connections.") }
            .task {
                health.configureDietaryExport(accountId: store.accountId)
                do { try await store.refreshConnections(); connectionError = nil }
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
}

private struct DeveloperView: View {
    @Environment(FoodStore.self) private var store
    @Environment(HealthEnergy.self) private var health
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Apple Health") {
                    Button("Refresh Health data") {
                        Task {
                            if health.requested { await health.refresh() }
                            else { await health.connect() }
                        }
                    }
                    if let error = health.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                Section("Dietary Energy") {
                    if let accountId = store.accountId {
                        if health.dietaryExportEnabled && health.dietaryExportAuthorized {
                            Label("New food logs are written to Apple Health", systemImage: "checkmark.circle.fill")
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
                }
            }
            .navigationTitle("Developer")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

struct ManualWeightView: View {
    @Environment(FoodStore.self) private var store
    @Environment(HealthEnergy.self) private var health
    @Environment(\.dismiss) private var dismiss
    @State private var weightKg = 70.0
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
            .onAppear { weightKg = health.usableLatestWeightKg ?? store.profile?.weightKg ?? 70 }
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
                onLogged(weightKg)
                dismiss()
            } catch { errorText = error.localizedDescription }
        }
    }
}
