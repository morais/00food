import AppIntents
import Foundation

struct LogSavedFoodIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a Saved Food"
    static let description = IntentDescription("Logs one saved food in 00Food today using its exact name and saved amount.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Saved food name", description: "The full name of the saved food in 00Food.")
    var foodName: String

    static var parameterSummary: some ParameterSummary { Summary("Log \(\.$foodName)") }

    @Dependency private var store: FoodStore

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let requestedName = foodName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedName.isEmpty else { return .result(dialog: "Say the full name of a saved food.") }
        try await store.prepareForFoodIntent()
        let matches = store.foods.filter { $0.name.compare(requestedName, options: .caseInsensitive) == .orderedSame }
        guard let food = matches.first else {
            return .result(dialog: "There’s no saved food named \(requestedName) in 00Food.")
        }
        guard matches.count == 1 else {
            return .result(dialog: "More than one saved food is named \(food.name). Open 00Food to choose one.")
        }
        try await store.log(food)
        return .result(dialog: "Logged \(food.name) in 00Food.")
    }
}

struct RequestFoodEstimateIntent: AppIntent {
    static let title: LocalizedStringResource = "Request a Food Estimate"
    static let description = IntentDescription("Sends a description of food eaten today to the connected 00Food agent for a calorie estimate to review.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Meal description", description: "The food and any portion or ingredient details the person provides.")
    var mealDescription: String

    static var parameterSummary: some ParameterSummary { Summary("Estimate \(\.$mealDescription)") }

    @Dependency private var store: FoodStore

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let meal = mealDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...500).contains(meal.utf16.count) else {
            throw FoodServiceError(message: "Describe the food in 1 to 500 characters.")
        }
        try await store.prepareForFoodIntent()
        let session = store.token
        let requestID = UUID().uuidString.lowercased()
        try await store.requestEstimate(description: meal, photo: nil, id: requestID)
        if !store.isOffline { try? await store.refreshAndWait(quiet: true) }
        if store.token == session,
           let request = store.estimations.first(where: { $0.id == requestID }), request.state != "uploading" {
            return .result(dialog: "Sent your estimate request. You can review the estimate when your agent replies.")
        }
        return .result(dialog: "Queued your estimate request. You can review the estimate when your agent replies.")
    }
}

struct GetTodayLoggedCaloriesIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Today’s Logged Calories"
    static let description = IntentDescription("Gets the calories already logged in 00Food today.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Dependency private var store: FoodStore

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        try await store.prepareForFoodIntent(refresh: true)
        let calories = store.consumedToday
        return .result(value: calories, dialog: "You’ve logged \(calories) calories today in 00Food.")
    }
}

struct GetPendingFoodEstimatesIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Pending Food Estimates"
    static let description = IntentDescription("Reports which 00Food estimates are ready to approve and how many requests are still waiting.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Dependency private var store: FoodStore

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let refreshed = try await store.prepareForFoodIntent(refresh: true)
        let estimates = store.estimations
        let ready = estimates.compactMap { $0.state == "proposed" ? $0.proposedName : nil }
        let waiting = estimates.count { $0.state == "pending" }
        let uploading = estimates.count { $0.state == "uploading" }
        var status: [String] = []
        if !refreshed { status.append(String(localized: "From the estimates saved on this iPhone.")) }
        if ready.isEmpty {
            status.append(String(localized: "No estimates are ready to approve."))
        } else {
            let names = ready.prefix(5).formatted(.list(type: .and))
            status.append(String(localized: "Ready to approve (\(ready.count)): \(names)."))
            if ready.count > 5 { status.append(String(localized: "Open 00Food to see the full list.")) }
        }
        if waiting > 0 { status.append(String(localized: "Waiting for the agent: \(waiting).")) }
        if uploading > 0 { status.append(String(localized: "Waiting to sync: \(uploading).")) }
        return .result(dialog: "\(status.joined(separator: " "))")
    }
}

struct ApproveFoodEstimateIntent: AppIntent {
    static let title: LocalizedStringResource = "Approve a Food Estimate"
    static let description = IntentDescription("Confirms and logs one ready 00Food agent estimate using its proposed food name.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Proposed food name", description: "The exact name the agent proposed. You can leave it blank if only one estimate is ready.")
    var estimateName: String?

    static var parameterSummary: some ParameterSummary { Summary("Approve estimate for \(\.$estimateName)") }

    @Dependency private var store: FoodStore

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let refreshed = try await store.prepareForFoodIntent(refresh: true)
        guard refreshed else {
            return .result(dialog: "00Food needs to sync before you can approve an estimate.")
        }

        let ready = store.estimations.filter { $0.state == "proposed" }
        guard !ready.isEmpty else { return .result(dialog: "No estimates are ready to approve.") }

        let session = store.token
        var requestedName = estimateName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if requestedName.isEmpty && ready.count > 1 {
            let names = ready.prefix(5).compactMap(\.proposedName).formatted(.list(type: .and))
            let answer: String? = try await $estimateName.requestValue("Which estimate should I approve? Ready estimates include \(names).")
            requestedName = answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !requestedName.isEmpty else { return .result(dialog: "Say the name of the estimate to approve.") }
        }
        let matches = requestedName.isEmpty ? ready : ready.filter {
            $0.proposedName?.compare(requestedName, options: .caseInsensitive) == .orderedSame
        }
        guard let proposal = matches.first, let name = proposal.proposedName,
              let serving = proposal.proposedServing, let calories = proposal.proposedKcal else {
            return .result(dialog: "There’s no estimate ready to approve for \(requestedName).")
        }
        guard matches.count == 1 else {
            return .result(dialog: "Multiple estimates are named \(name). Open 00Food to choose one.")
        }

        let day = proposal.mealTimestamp?.formatted(date: .abbreviated, time: .omitted) ?? proposal.localDate
        try await requestConfirmation(actionName: .log, dialog: "Approve and log \(name), \(serving), at \(calories) calories for \(day)?")
        guard store.token == session else {
            throw FoodServiceError(message: "The 00Food account changed. Try again from the current account.")
        }
        try await store.accept(proposal, matchingProposal: true)
        return .result(dialog: "Approved and logged \(name) in 00Food.")
    }
}

struct ClarifyFoodEstimateIntent: AppIntent {
    static let title: LocalizedStringResource = "Clarify a Food Estimate"
    static let description = IntentDescription("Sends a correction or extra portion or ingredient details about an existing open 00Food estimate to the connected agent.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Clarification", description: "The new details or correction to send to the agent.")
    var clarification: String

    @Parameter(title: "Open estimate", description: "The proposed food name or part of the original meal description. Leave blank if only one estimate is open.")
    var estimateName: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Clarify \(\.$estimateName) with \(\.$clarification)")
    }

    @Dependency private var store: FoodStore

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await store.prepareForFoodIntent(refresh: true)
        guard !store.estimations.isEmpty else { return .result(dialog: "There are no open food estimates in 00Food.") }

        let session = store.token
        var requestedName = estimateName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if requestedName.isEmpty && store.estimations.count > 1 {
            let examples = store.estimations.prefix(3).map { String($0.displayName.prefix(80)) }.formatted(.list(type: .and))
            let answer: String? = try await $estimateName.requestValue("Which estimate should I clarify? Open estimates include \(examples).")
            requestedName = answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !requestedName.isEmpty else { return .result(dialog: "Say the name of the estimate to clarify.") }
        }
        guard store.token == session else {
            throw FoodServiceError(message: "The 00Food account changed. Try again from the current account.")
        }

        let matches = Self.matches(in: store.estimations, name: requestedName)
        guard let estimate = matches.first else { return .result(dialog: "I couldn’t find an open estimate for \(requestedName).") }
        guard matches.count == 1 else {
            return .result(dialog: "Several open estimates match. Give a more specific name or choose the estimate in 00Food.")
        }

        try store.clarifyEstimate(id: estimate.id, text: clarification)
        if store.isOffline {
            return .result(dialog: "Saved your clarification. It will send when 00Food syncs.")
        }
        let synced = (try? await store.refreshAndWait(quiet: true)) != nil
        if store.token == session {
            guard store.estimations.contains(where: { $0.id == estimate.id }) else {
                return .result(dialog: "That estimate is now closed.")
            }
            if synced { return .result(dialog: "Sent your clarification to your connected agent.") }
        }
        return .result(dialog: "Saved your clarification in 00Food.")
    }

    static func matches(in estimates: [PendingEstimation], name: String) -> [PendingEstimation] {
        guard !name.isEmpty else { return estimates }
        let exact = estimates.filter {
            $0.displayName.compare(name, options: .caseInsensitive) == .orderedSame ||
            $0.description.compare(name, options: .caseInsensitive) == .orderedSame
        }
        if !exact.isEmpty { return exact }
        return estimates.filter {
            $0.displayName.localizedCaseInsensitiveContains(name) || $0.description.localizedCaseInsensitiveContains(name)
        }
    }
}

struct FoodAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LogSavedFoodIntent(), phrases: ["Log a saved food in \(.applicationName)"],
                    shortTitle: "Log Saved Food", systemImageName: "fork.knife")
        AppShortcut(intent: RequestFoodEstimateIntent(), phrases: ["Request a food estimate in \(.applicationName)"],
                    shortTitle: "Request Estimate", systemImageName: "text.bubble")
        AppShortcut(intent: GetTodayLoggedCaloriesIntent(), phrases: ["How many calories have I logged today in \(.applicationName)"],
                    shortTitle: "Today’s Calories", systemImageName: "number")
        AppShortcut(intent: GetPendingFoodEstimatesIntent(), phrases: ["Check pending estimates in \(.applicationName)"],
                    shortTitle: "Pending Estimates", systemImageName: "list.bullet")
        AppShortcut(intent: ApproveFoodEstimateIntent(), phrases: ["Approve a food estimate in \(.applicationName)"],
                    shortTitle: "Approve Estimate", systemImageName: "checkmark.circle")
        AppShortcut(intent: ClarifyFoodEstimateIntent(), phrases: ["Clarify a food estimate in \(.applicationName)"],
                    shortTitle: "Clarify Estimate", systemImageName: "text.bubble")
    }
}

private extension FoodStore {
    @discardableResult
    func prepareForFoodIntent(refresh: Bool = false) async throws -> Bool {
        let session = token
        guard signedIn else { throw FoodServiceError(message: "Sign in to 00Food on your iPhone first.") }

        var refreshed = false
        if !isOffline && (refresh || !hasLoadedSnapshot) {
            do {
                try await refreshAndWait(quiet: true)
                refreshed = true
            } catch is FoodServiceError {
                // A signed-in account can still use its saved snapshot while offline.
            }
        }
        guard token == session, hasLoadedSnapshot, profile != nil else {
            throw FoodServiceError(message: "Open 00Food to finish loading and setting up your account.")
        }
        return refreshed
    }
}

#if FOOD_SIRI_AI_TOOLS
// The tool macro adds this conformance. Keeping it on an extension also
// makes the underlying App Shortcut available on iOS 27.0 through 27.2.
@available(iOS 27.3, *)
extension LogSavedFoodIntent: ToolIntent {}
@available(iOS 27.3, *)
extension RequestFoodEstimateIntent: ToolIntent {}
@available(iOS 27.3, *)
extension GetTodayLoggedCaloriesIntent: ToolIntent {}
@available(iOS 27.3, *)
extension GetPendingFoodEstimatesIntent: ToolIntent {}
@available(iOS 27.3, *)
extension ApproveFoodEstimateIntent: ToolIntent {}
@available(iOS 27.3, *)
extension ClarifyFoodEstimateIntent: ToolIntent {}
#endif
