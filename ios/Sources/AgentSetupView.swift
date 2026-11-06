import SwiftUI
import UIKit

enum AgentSetupProvider: String, CaseIterable, Identifiable {
    case chatgpt = "ChatGPT", claude = "Claude"
    var id: Self { self }
    var listingURL: URL {
        switch self {
        case .chatgpt: URL(string: "https://chatgpt.com/plugins/plugin_asdk_app_6aca59ae4a548191a8f0d965ed5f56ba")!
        case .claude: URL(string: "https://claude.ai/directory/00food")!
        }
    }
}

enum AgentSetupCopy {
    static func instructions(for provider: AgentSetupProvider) -> String {
        let monitoring = provider == .chatgpt
            ? "Subscribe to food.estimate_requested and food.clarification_added so you can respond to new requests and revise estimates when I add context. Subscribe to food.logged for context; do not estimate foods that I have already approved. Confirm which event subscriptions are active. If this client cannot subscribe to events, explain that I need to ask you to check pending requests manually."
            : "Check pending foods and clarifications when I ask. Do not claim to monitor requests in the background or subscribe to events. Do not estimate foods that I have already approved."
        let dailyFollowUp = provider == .chatgpt
            ? "subscribe to day.feedback_requested"
            : "check pending daily review requests when I ask"
        return """
    Use 00Food as my food log companion. Check my pending foods now. For each request, read the description and inspect any attached photo, then propose a rough calorie estimate and fruit-and-vegetable portions with a short explanation. I will review each proposal in 00Food before it is saved or logged.

    \(monitoring)

    Ask me whether I want daily reviews. If I do, call list_pending_daily_feedback and let me approve the additional permissions, then \(dailyFollowUp). Read each requested day's food and available Health summaries and follow its reviewGuidance, including the preferred display units. Five fruit/vegetable portions means at least five; recorded water is a minimum, so meeting the water goal does not mean I stopped there. Include a brief reflection on protein sources and overall diet variety from the logged foods, without inventing nutrient grams or assuming the logs are complete. Note missing data and avoid diagnoses or prescriptive calorie advice. Do not enable daily feedback in the app on my behalf.

    Use light Markdown for daily reviews: short headings or bullet points and bold/italic emphasis where useful. Cite any health or nutrition recommendations with clickable source links, following reviewGuidance and referenceSources. Keep it concise; avoid tables, HTML, images and code blocks.
    """
    }
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
    @State private var provider: AgentSetupProvider = .chatgpt

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
                    Picker("Your agent", selection: $provider) {
                        ForEach(AgentSetupProvider.allCases) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    Link(destination: provider.listingURL) {
                        Label("Add to \(provider.rawValue)", systemImage: "arrow.up.right.square")
                    }
                    Text(provider == .chatgpt
                         ? "Open the published 00Food plugin and install it in ChatGPT. Connect 00Food when prompted."
                         : "Open 00Food in the Claude Directory and add the connector to Claude. Connect 00Food when prompted.")
                    Text("Sign in with the same Apple account you use in 00Food and approve the requested permissions.")
                        .font(.footnote).foregroundStyle(.secondary)
                    DisclosureGroup("Other agents / custom server") {
                        Text("For another compatible agent, add this address as a remote MCP server and sign in with the same Apple account.")
                        Text(store.mcpAddress).font(.footnote.monospaced()).textSelection(.enabled)
                        Button(copiedAddress ? "Address copied" : "Copy MCP address", systemImage: copiedAddress ? "checkmark" : "doc.on.doc") {
                            UIPasteboard.general.string = store.mcpAddress
                            copiedAddress = true
                        }
                    }
                }
                Section("2. Tell your agent how to help") {
                    Text(provider == .chatgpt
                         ? "Start a Work chat on ChatGPT web, or select Work and Cloud in the desktop app. Add the 00Food plugin to the chat, then paste these instructions."
                         : "Start a Claude chat with the 00Food connector enabled, then paste these instructions. Ask Claude to check pending foods or daily reviews whenever you want a response.")
                    Button(copiedInstructions ? "Instructions copied" : "Copy agent instructions", systemImage: copiedInstructions ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = AgentSetupCopy.instructions(for: provider)
                        copiedInstructions = true
                    }
                    DisclosureGroup("Read the instructions") {
                        Text(AgentSetupCopy.instructions(for: provider)).font(.footnote).textSelection(.enabled)
                    }
                }
                Section("3. Check your connection") {
                    Text(provider == .chatgpt
                         ? "Return here after connecting and refresh. For automatic responses in ChatGPT Work, paste the instructions above so it subscribes to new requests. Connecting alone does not enable automatic responses."
                         : "Return here after connecting and refresh. Connected means Claude can access the account you approved. Claude checks requests when you ask; this connection does not enable automatic background responses.")
                    if !store.signedIn {
                        Text("Sign in to 00Food before checking your agent connections.").foregroundStyle(.secondary)
                    } else if let connectionError {
                        Text(connectionError).font(.footnote).foregroundStyle(.orange)
                    } else if store.hasLoadedConnections && store.connections.isEmpty {
                        Text("No connected agents yet. Finish step 1, then refresh here.").foregroundStyle(.secondary)
                    }
                    if connectionError == nil {
                        ForEach(store.connections) { connection in
                            AgentConnectionDetails(connection: connection, showEventSubscriptions: provider == .chatgpt)
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
                    Text(provider == .chatgpt
                         ? "Active subscriptions confirm that events are enabled. Your agent's response also depends on its instructions and availability."
                         : "Try asking: “Check my pending foods in 00Food and propose estimates for me to review.”")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Daily reviews are your choice") {
                    Text("To request reviews automatically, turn on Request a daily review in Settings. You can also request a past day from the food log. Your agent needs your approval to read the food and Health summaries and save feedback.")
                    Text("With Claude, ask it to check pending daily reviews after the app sends a request.")
                        .font(.footnote).foregroundStyle(.secondary)
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
            .onChange(of: provider) { _, _ in copiedInstructions = false }
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
    var showEventSubscriptions = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(connection.clientName).font(.headline)
            Label("Connected", systemImage: "checkmark.circle").labelStyle(.tintedIcon(.green))
            if showEventSubscriptions, let events = connection.activeEvents {
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
            } else if showEventSubscriptions {
                Text("Event subscription status unavailable").foregroundStyle(.secondary)
            }
            let dailyAccess = connection.scopes.contains("daily:read") && connection.scopes.contains("daily:write")
            Text(dailyAccess ? "Daily review access granted" : "Daily review access not granted")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}
