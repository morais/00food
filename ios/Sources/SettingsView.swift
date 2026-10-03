import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(FoodStore.self) private var store
    @Environment(HealthEnergy.self) private var health
    @Environment(\.dismiss) private var dismiss
    @State private var showingProfile = false
    @State private var showingDelete = false
    @State private var confirmingDelete = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if let email = store.accountEmail { Text(email).foregroundStyle(.secondary) }
                    Button("Your details & target") { showingProfile = true }
                    Button("Sign out") { Task { await store.signOut(); dismiss() } }
                    Button("Delete account and food data", role: .destructive) { confirmingDelete = true }
                }
                Section("Apple Health") {
                    HStack {
                        Text("Active energy today")
                        Spacer()
                        Text("\(health.activeKcal) kcal").foregroundStyle(.secondary)
                    }
                    Button(health.requested ? "Refresh Health data" : "Connect Apple Health") {
                        Task {
                            if health.requested { await health.refresh() }
                            else { await health.connect() }
                        }
                    }
                    if let error = health.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
                    Text("Health data is read on this device and is not sent to 00Food.")
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
            .sheet(isPresented: $showingDelete) { DeleteAccountView() }
            .confirmationDialog("Delete your account and all food data?", isPresented: $confirmingDelete) {
                Button("Continue to Apple verification", role: .destructive) { showingDelete = true }
            } message: { Text("This removes your profile, foods, logs, estimates, photos, and agent connections.") }
            .task { try? await store.refreshConnections() }
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
