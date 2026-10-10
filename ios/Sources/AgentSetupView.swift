import SwiftUI
import UIKit

enum AgentSetupCopy {
    static let instructions = """
    Use 00Food as my food log companion. Check my pending foods now. For each request, read the description and inspect any attached photo, then propose a rough calorie estimate and fruit-and-vegetable portions with a short explanation. I will review each proposal in 00Food before it is saved or logged.

    Subscribe to food.estimate_requested and food.clarification_added so you can respond to new requests and revise estimates when I add context. Subscribe to food.logged for context; do not estimate foods that I have already approved.

    Ask me whether I want daily reviews. If I do, call list_pending_daily_feedback and let me approve the additional permissions, then subscribe to day.feedback_requested. Read each requested day's food and available Health summaries and follow its reviewGuidance, including the preferred display units. Five fruit/vegetable portions means at least five; recorded water is a minimum, so meeting the water goal does not mean I stopped there. Include a brief reflection on protein sources and overall diet variety from the logged foods, without inventing nutrient grams or assuming the logs are complete. Note missing data and avoid diagnoses or prescriptive calorie advice. Do not enable daily feedback in the app on my behalf.

    Use light Markdown for daily reviews: short headings or bullet points and bold/italic emphasis where useful. Keep it concise; avoid tables, HTML, images and code blocks.

    Confirm which event subscriptions are active. If this client cannot subscribe to events, explain that I need to ask you to check pending requests manually.
    """
}

struct AgentSetupView: View {
    var onCompleted: (() -> Void)? = nil
    @Environment(FoodStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var copiedAddress = false
    @State private var copiedInstructions = false
    @State private var refreshing = false
    @State private var connectionError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Your food log. Your AI agent.").font(.headline)
                    Text("00Food has no built-in food catalogue or bundled AI agent. Connect your favourite compatible agent to estimate new foods and help you review your day. You approve the estimates and build your own reusable library.")
                    Text("Manual logging is always available.").font(.footnote).foregroundStyle(.secondary)
                    if onCompleted != nil {
                        Text("You can connect now or start logging and return here from Settings.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("1. Connect your agent") {
                    Text("ChatGPT Work is the recommended setup for automatic responses. In ChatGPT Plugins, choose Add custom MCP server, paste this address, and sign in with the same Apple account you use in 00Food.")
                    Text(store.mcpAddress).font(.footnote.monospaced()).textSelection(.enabled)
                    Button(copiedAddress ? "Address copied" : "Copy MCP address", systemImage: copiedAddress ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = store.mcpAddress
                        copiedAddress = true
                    }
                    Text("Other compatible MCP agents can check pending requests when you ask them.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("2. Tell your agent how to help") {
                    Text("Start a Work chat on ChatGPT web, or select Work and Cloud in the desktop app. Add your 00Food plugin to the chat, then paste these instructions.")
                    Button(copiedInstructions ? "Instructions copied" : "Copy agent instructions", systemImage: copiedInstructions ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = AgentSetupCopy.instructions
                        copiedInstructions = true
                    }
                    DisclosureGroup("Read the instructions") {
                        Text(AgentSetupCopy.instructions).font(.footnote).textSelection(.enabled)
                    }
                }
                Section("3. Check event subscriptions") {
                    Text("MCP Events lets your agent respond when you request an estimate or daily review, without you asking it to check each time. Connecting alone does not subscribe to events: ask your agent to monitor them using the instructions above.")
                    if !store.signedIn {
                        Text("Sign in to 00Food before checking your agent connections.").foregroundStyle(.secondary)
                    } else if let connectionError {
                        Text(connectionError).font(.footnote).foregroundStyle(.orange)
                    } else if store.hasLoadedConnections && store.connections.isEmpty {
                        Text("No connected agents yet. Finish step 1, then refresh here.").foregroundStyle(.secondary)
                    }
                    if connectionError == nil {
                        ForEach(store.connections) { connection in
                            AgentConnectionDetails(connection: connection)
                        }
                    }
                    Button {
                        Task { await refresh() }
                    } label: {
                        HStack {
                            Text("Refresh connection status")
                            if refreshing { ProgressView() }
                        }
                    }
                    .disabled(refreshing || !store.signedIn)
                    Text("Active subscriptions confirm that events are enabled. Your agent's response also depends on the instructions and availability of its client.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Daily reviews are your choice") {
                    Text("To request reviews automatically, turn on Request a daily review in Settings. You can also request a past day from the food log. Your agent needs your approval to read the food and Health summaries and save feedback.")
                    Link("ChatGPT Work and MCP Events setup", destination: URL(string: "https://developers.openai.com/plugins/build/mcp-events")!)
                }
            }
            .navigationTitle("Connect your agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(onCompleted == nil ? "Done" : "Start logging") {
                        if let onCompleted { onCompleted() }
                        else { dismiss() }
                    }
                }
            }
            .task { await refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refresh() } }
            }
        }
    }

    private func refresh() async {
        guard store.signedIn else { return }
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            try await store.refreshConnections(force: true)
            connectionError = nil
        } catch {
            connectionError = "Could not check current connection status. Connect to the internet and refresh to try again."
        }
    }
}

struct AgentConnectionDetails: View {
    let connection: MCPConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(connection.clientName).font(.headline)
            Label("Connected", systemImage: "checkmark.circle").labelStyle(.tintedIcon(.green))
            if let events = connection.activeEvents {
                if events.isEmpty {
                    Label("No active event subscriptions", systemImage: "exclamationmark.triangle")
                        .labelStyle(.tintedIcon(.orange))
                } else {
                    if events.contains("food.estimate_requested") {
                        Text("New food requests: subscribed")
                    }
                    if events.contains("food.clarification_added") {
                        Text("Estimate clarifications: subscribed")
                    }
                    if events.contains("food.logged") {
                        Text("Food logs: subscribed")
                    }
                    if events.contains("day.feedback_requested") {
                        Text("Daily review requests: subscribed")
                    }
                }
            } else {
                Text("Event subscription status unavailable").foregroundStyle(.secondary)
            }
            let dailyAccess = connection.scopes.contains("daily:read") && connection.scopes.contains("daily:write")
            Text(dailyAccess ? "Daily review access granted" : "Daily review access not granted")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}
