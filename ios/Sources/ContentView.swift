import SwiftUI
import WidgetKit

struct RootView: View {
    @Binding var replayOnboarding: Bool
    @Environment(FoodStore.self) private var store
    @Environment(HealthEnergy.self) private var health
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("activeDayStartMinutes") private var activeDayStartMinutes = 7 * 60
    @AppStorage("activeDayEndMinutes") private var activeDayEndMinutes = 23 * 60
    @AppStorage(FoodWidgetSnapshotStore.pendingLaunchKey, store: FoodWidgetSnapshotStore.sharedDefaults)
    private var pendingWidgetLaunch = ""
    @State private var errorText: String?
    @State private var feedbackSyncing = false
    @State private var onboardingSession = OnboardingSession()

    init(replayOnboarding: Binding<Bool> = .constant(false)) {
        _replayOnboarding = replayOnboarding
    }

    private var responsePollingScope: AgentResponsePolling.Scope {
        .init(accountToken: store.token, active: scenePhase == .active,
              online: !store.isOffline, requests: store.pendingAgentResponseKeys)
    }
    private var pushScope: AgentResponsePush.Scope {
        .init(account: store.token, device: AgentResponsePush.shared.deviceToken,
              active: scenePhase == .active, online: !store.isOffline)
    }

    private var widgetSnapshot: FoodWidgetSnapshot? {
        guard store.signedIn, let profile = store.profile else { return nil }
        let budget = health.dailyBudget(for: profile)
        return FoodWidgetSnapshot(localDate: FoodDates.today(),
                                  // Legacy cached snapshots add active energy to this bridge value.
                                  targetKcal: budget.allowanceKcal - health.activeKcal,
                                  consumedKcal: store.consumedToday, activeKcal: health.activeKcal,
                                  pendingCount: store.estimations.count, startMinutes: activeDayStartMinutes,
                                  endMinutes: activeDayEndMinutes, budgetKcal: budget.allowanceKcal)
    }

    var body: some View {
        Group {
            if !store.signedIn { SignInView() }
            else if !store.hasLoadedSnapshot { accountLoadView }
            else if onboardingSession.isPresented(hasProfile: store.profile != nil, replay: replayOnboarding) {
                OnboardingView(onCompleted: {
                    replayOnboarding = false
                    onboardingSession.finish()
                })
                .onAppear { onboardingSession.start() }
            }
            else { HomeView() }
        }
        .task {
            health.resetReadingsForNewDay()
            if UserDefaults.standard.string(forKey: "foodControlIconsVersion") != "3" {
                ControlCenter.shared.reloadAllControls()
                UserDefaults.standard.set("3", forKey: "foodControlIconsVersion")
            }
            openPendingWidgetLaunch()
            if store.signedIn && scenePhase == .active {
                do { try await store.refresh(force: true) } catch { errorText = error.localizedDescription }
                health.setHistoryStart(store.accountStartedAt)
                await health.refresh()
                syncDietaryEnergy()
                await queueDailyFeedback()
            }
        }
        .task(id: responsePollingScope) {
            guard responsePollingScope.shouldPoll else { return }
            await AgentResponsePolling.run {
                // Conditional snapshot requests keep the current UI and Health readings in place.
                try? await store.refresh(force: true, quiet: true)
            }
        }
        .task(id: pushScope) {
            guard pushScope.active, pushScope.online else { return }
            await AgentResponsePush.shared.registerDevice(using: store)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                health.resetReadingsForNewDay()
                openPendingWidgetLaunch()
            }
            if phase == .active && store.signedIn {
                Task {
                    try? await store.refresh(force: true)
                    try? await store.refreshConnections()
                    health.setHistoryStart(store.accountStartedAt)
                    await health.refresh()
                    syncDietaryEnergy()
                    await queueDailyFeedback()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            guard store.signedIn, scenePhase == .active else { return }
            health.resetReadingsForNewDay()
            Task {
                try? await store.refresh(force: true)
                await health.refresh()
                await queueDailyFeedback()
            }
        }
        .onChange(of: store.signedIn) { _, signedIn in
            if !signedIn { onboardingSession.finish() }
        }
        .onChange(of: store.dailyFeedbackEnabled) { _, enabled in
            if enabled { Task { await queueDailyFeedback() } }
        }
        .onOpenURL { url in
            if let launch = FoodQuickLaunch(url: url) { FoodQuickActions.shared.pendingLaunch = launch }
        }
        .onChange(of: pendingWidgetLaunch) { _, _ in openPendingWidgetLaunch() }
        .onChange(of: widgetSnapshot, initial: true) { _, snapshot in
            if let snapshot { FoodWidgetSnapshotStore.save(snapshot) }
            else { FoodWidgetSnapshotStore.clear() }
        }
        .onChange(of: health.dietaryWriteAuthorized) { _, _ in syncDietaryEnergy() }
        .onChange(of: store.logs, initial: true) { _, _ in syncDietaryEnergy() }
        .onChange(of: store.accountId) { _, _ in syncDietaryEnergy() }
        .alert("Could not refresh", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private func openPendingWidgetLaunch() {
        guard let launch = FoodQuickLaunch(rawValue: pendingWidgetLaunch) else { return }
        pendingWidgetLaunch = ""
        FoodQuickActions.shared.pendingLaunch = launch
    }

    private func syncDietaryEnergy() {
        guard store.signedIn, store.hasLoadedSnapshot, let accountId = store.accountId else { return }
        health.configureDietaryExport(accountId: accountId)
        let logs = store.logs
        Task { await health.syncDietaryEnergy(logs: logs, accountId: accountId) }
    }

    private func queueDailyFeedback() async {
        guard !feedbackSyncing, scenePhase == .active else { return }
        feedbackSyncing = true
        defer { feedbackSyncing = false }
        do {
            _ = try await store.requestMissingDailyFeedback(using: health, includeHistory: false,
                                                           requireAccessibleHealth: true)
        }
        catch { store.syncError = "Could not save daily feedback request: \(error.localizedDescription)" }
    }

    private var accountLoadView: some View {
        VStack(spacing: 16) {
            Image(systemName: store.isOffline ? "wifi.slash" : "arrow.triangle.2.circlepath")
                .font(.largeTitle)
            Text("Connect to load your foods").font(.title2.bold())
            Text("Your account needs one successful sync on this iPhone before it can work offline.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if let syncError = store.syncError {
                Text(syncError).font(.footnote).foregroundStyle(.red)
            }
            Button("Try again") { Task { try? await store.refresh(force: true) } }
                .buttonStyle(.borderedProminent)
            Button("Sign out") {
                Task {
                    do { try await store.signOut() }
                    catch { errorText = error.localizedDescription }
                }
            }
        }
        .padding(30)
    }
}

private struct WaterGlassIcon: View {
    let filled: Bool

    var body: some View {
        ZStack {
            if filled {
                Path { path in
                    path.move(to: CGPoint(x: 6, y: 14))
                    path.addLine(to: CGPoint(x: 22, y: 14))
                    path.addLine(to: CGPoint(x: 19, y: 28))
                    path.addLine(to: CGPoint(x: 9, y: 28))
                    path.closeSubpath()
                }
                .fill(.blue.opacity(0.8))
            }
            Path { path in
                path.move(to: CGPoint(x: 4, y: 3))
                path.addLine(to: CGPoint(x: 24, y: 3))
                path.addLine(to: CGPoint(x: 19, y: 29))
                path.addLine(to: CGPoint(x: 9, y: 29))
                path.closeSubpath()
            }
            .stroke(filled ? Color.blue : Color.secondary.opacity(0.6),
                    style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
        .frame(width: 28, height: 32)
        .accessibilityHidden(true)
    }
}

struct HomeView: View {
    @Environment(FoodStore.self) private var store
    @ScaledMetric(relativeTo: .largeTitle) private var balanceSize: CGFloat = 48
    @Environment(HealthEnergy.self) private var health
    @State private var shortcuts = FoodQuickActions.shared
    @State private var addLaunch: FoodQuickLaunch?
    @State private var backdatedLogDate: Date?
    @State private var showingSettings = false
    @State private var showingAgentSetup = false
    @State private var showingProgress = false
    @State private var reviewing: PendingEstimation?
    @State private var errorText: String?
    @State private var deletingLogID: String?
    @State private var selectedLogDate = Calendar.current.startOfDay(for: Date())
    @State private var selectedWaterMl: Int?
    @State private var selectedWaterError: String?
    @State private var selectedWaterRequestID = UUID()
    @State private var showingBalanceDetails = false
    @State private var showingSelectedFeedback = false
    @State private var requestingSelectedFeedback = false

    private var remaining: Int {
        guard let profile = store.profile else { return 0 }
        return health.dailyBudget(for: profile).allowanceKcal - store.consumedToday
    }
    private var selectedLogs: [FoodLog] { store.logs(on: selectedLogDate) }
    private var selectedFeedback: DailyFeedbackRequest? {
        store.dailyFeedback.first { $0.localDate == FoodDates.localDate(for: selectedLogDate) }
    }
    private var selectedDayIsToday: Bool { Calendar.current.isDateInToday(selectedLogDate) }
    private var selectedFruitVegPortions: Int {
        min(5, selectedLogs.reduce(0) { $0 + $1.countedFruitVegPortions })
    }
    private var selectedWaterGlasses: String {
        guard let selectedWaterMl else { return "—" }
        return (Double(selectedWaterMl) / 250).formatted(.number.precision(.fractionLength(0...1)))
    }
    private var selectedWaterAccessibilityLabel: String {
        guard let selectedWaterMl else { return "Water unavailable" }
        return selectedWaterMl >= 2000 ? "Water goal met: at least 8 glasses" : "\(selectedWaterGlasses) glasses of water"
    }
    private var readyEstimateCount: Int { store.estimations.filter { $0.state == "proposed" }.count }
    private var offlineEstimateCount: Int { store.estimations.filter { $0.state == "uploading" }.count }
    private var waitingEstimateCount: Int { store.estimations.count - readyEstimateCount - offlineEstimateCount }
    private var earliestLogDate: Date {
        Calendar.current.date(byAdding: .day, value: -89, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 24) {
                        if store.isOffline || store.pendingSyncCount > 0 {
                            syncStatus
                        } else {
                            DelayedNotice(message: store.syncError, isRefreshing: store.isSyncing) { _ in syncStatus }
                        }
                        if store.hasLoadedConnections && store.connections.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Your food log. Your AI agent.").font(.headline)
                                Text("Connect your agent to estimate new foods and help you review your day. Your personal food library grows from estimates you approve.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Button("Connect your agent") { showingAgentSetup = true }
                                    .buttonStyle(.borderedProminent)
                                Text("You can also log foods manually.").font(.footnote).foregroundStyle(.secondary)
                            }
                            .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        }
                        balanceCard
                        Button { backdatedLogDate = nil; addLaunch = .log } label: {
                            Label("Log food", systemImage: "plus.circle.fill")
                                .font(.headline).frame(maxWidth: .infinity).frame(height: 48)
                        }
                        .buttonStyle(.borderedProminent)
                        if !store.estimations.isEmpty { estimatesSection }
                        hydrationCard
                        fiveADayCard
                        if store.dailyFeedbackEnabled || !store.dailyFeedback.isEmpty {
                            dailyFeedbackCard
                        }

                        foodLogSection
                    }
                    .frame(width: max(0, geometry.size.width - 40), alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 28)
                }
            }
            .swipeActionsContainer()
            .navigationTitle("00Food")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showingProgress = true } label: { Image(systemName: "chart.xyaxis.line") }
                        .accessibilityLabel("Progress and calorie plans")
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(item: $addLaunch) { launch in
                QuickAddView(openCameraOnAppear: launch == .camera, logDate: backdatedLogDate)
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $showingAgentSetup) { AgentSetupView() }
            .sheet(isPresented: $showingProgress) { ProgressPlansView() }
            .sheet(item: $reviewing) { ReviewEstimationView(estimation: $0) }
            .sheet(isPresented: $showingSelectedFeedback) { selectedFeedbackSheet }
            .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
            .refreshable {
                try? await store.refresh(force: true)
                try? await store.refreshConnections(force: true)
                health.setHistoryStart(store.accountStartedAt)
                await health.refresh()
                await loadSelectedWater(on: selectedLogDate)
            }
            .task {
                try? await store.refreshConnections()
                health.setHistoryStart(store.accountStartedAt)
                await health.refresh()
            }
            .onAppear { openPendingShortcut() }
            .task(id: FoodDates.localDate(for: selectedLogDate)) {
                await loadSelectedWater(on: selectedLogDate)
            }
            .onChange(of: health.waterRequested) { _, _ in
                Task { await loadSelectedWater(on: selectedLogDate) }
            }
            .onChange(of: shortcuts.pendingLaunch) { _, _ in openPendingShortcut() }
        }
    }

    private func openPendingShortcut() {
        guard let launch = shortcuts.pendingLaunch else { return }
        shortcuts.pendingLaunch = nil
        backdatedLogDate = nil
        let hasPresentedSheet = addLaunch != nil || showingSettings || showingAgentSetup || showingProgress || reviewing != nil
        if hasPresentedSheet {
            addLaunch = nil
            showingSettings = false
            showingAgentSetup = false
            showingProgress = false
            reviewing = nil
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                addLaunch = launch
            }
        } else {
            addLaunch = launch
        }
    }

    private var syncStatus: some View {
        HStack(spacing: 10) {
            Image(systemName: store.isOffline ? "wifi.slash" : "arrow.triangle.2.circlepath")
            VStack(alignment: .leading, spacing: 2) {
                Text(store.isOffline ? "Offline · saved on this iPhone" :
                     store.pendingSyncCount > 0 ? "\(store.pendingSyncCount) change(s) waiting to sync" : "Sync needs attention")
                    .font(.subheadline.weight(.medium))
                if let syncError = store.syncError {
                    Text(syncError).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !store.isOffline {
                Button("Retry") { Task { try? await store.refresh(force: true) } }
                    .font(.subheadline)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showingBalanceDetails.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(remaining)").font(.system(size: balanceSize, weight: .bold, design: .rounded))
                    Text("kcal left").font(.headline).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: showingBalanceDetails ? "chevron.down" : "chevron.right")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(remaining) calories left")
            .accessibilityValue(showingBalanceDetails ? "Calculation shown" : "Calculation hidden")
            .accessibilityHint(showingBalanceDetails ? "Hide calculation" : "Show calculation")
            if showingBalanceDetails, let profile = store.profile {
                let resting = health.effectiveRestingKcal(for: profile)
                let budget = health.dailyBudget(for: profile)
                Text("TDEE (\(budget.tdeeKcal) kcal) = resting estimate (\(resting)) + active energy (\(health.activeKcal)). Allowance (\(budget.allowanceKcal) kcal) = TDEE − \(profile.deficitPercent)% gap (\(budget.gapKcal) kcal). Calories left = allowance − food.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Label("\(store.consumedToday) eaten", systemImage: "fork.knife")
                Label("\(health.activeKcal) active", systemImage: "figure.walk")
            }
            .font(.subheadline)
            if let profile = store.profile {
                ActiveDayComparison(allowanceKcal: health.dailyBudget(for: profile).allowanceKcal,
                                    eatenKcal: store.consumedToday, allowanceReady: health.allowanceIsReady)
            }
            if !store.estimations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if readyEstimateCount > 0 {
                        Label("\(readyEstimateCount) ready to review", systemImage: "checkmark.circle.fill")
                            .labelStyle(.tintedIcon(.blue))
                    }
                    if waitingEstimateCount > 0 {
                        Label("\(waitingEstimateCount) awaiting agent", systemImage: "clock")
                            .labelStyle(.tintedIcon(.orange))
                    }
                    if offlineEstimateCount > 0 {
                        Label("\(offlineEstimateCount) waiting to send", systemImage: "wifi.slash")
                            .foregroundStyle(.secondary)
                    }
                    Text("Not counted until you review and log them.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption.weight(.medium))
            }
            if !health.requested {
                Button("Connect Apple Health") { Task { await health.connect() } }
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.top, 8)
    }

    private var dailyFeedbackCard: some View {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())
        return VStack(alignment: .leading, spacing: 12) {
            Text(yesterday.map { "Yesterday, \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? "Yesterday")
                .font(.title3.bold())
            if let yesterday,
               let request = store.dailyFeedback.first(where: { $0.localDate == FoodDates.localDate(for: yesterday) }) {
                feedbackRow(request, showsDate: false)
            } else {
                Text("No review for yesterday yet.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func feedbackRow(_ request: DailyFeedbackRequest, showsDate: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if showsDate {
                let date = FoodDates.parseLocalDate(request.localDate)
                Text(date?.formatted(.dateTime.month(.abbreviated).day()) ?? request.localDate)
                    .font(.subheadline.weight(.semibold))
            }
            if request.state == "ready", let feedback = request.feedback {
                DailyReviewText(markdown: feedback)
            } else {
                Label("Waiting for your agent", systemImage: "clock")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var selectedFeedbackSheet: some View {
        NavigationStack {
            ScrollView {
                if let selectedFeedback {
                    feedbackRow(selectedFeedback)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            }
            .navigationTitle("Daily review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { showingSelectedFeedback = false }
            } }
        }
        .presentationDetents([.medium, .large])
    }

    private var estimatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Food estimates").font(.title3.bold())
            ForEach(store.estimations) { item in
                Button { reviewing = item } label: {
                    HStack {
                        Image(systemName: item.hasPhoto ? "photo" : "text.bubble")
                        VStack(alignment: .leading) {
                            Text(item.proposedName ?? (item.description.isEmpty ? "Food photo" : item.description))
                                .lineLimit(1).foregroundStyle(.primary)
                            estimateStatusBadge(for: item)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    private func estimateStatusBadge(for item: PendingEstimation) -> some View {
        let ready = item.state == "proposed"
        let offline = item.state == "uploading"
        let color: Color = ready ? .blue : offline ? .gray : .orange
        return Label(ready ? "Ready to review" : offline ? "Saved offline" : "Awaiting agent",
                     systemImage: ready ? "checkmark.circle.fill" : offline ? "wifi.slash" : "clock")
            .font(.caption.weight(.semibold))
            .labelStyle(.tintedIcon(color))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var hydrationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Water").font(.headline)
                Spacer()
                Text("\(health.waterMlToday.formatted()) mL today")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                ForEach(0..<8, id: \.self) { index in
                    Button { Task { await health.logWaterCup() } } label: {
                        WaterGlassIcon(filled: index < min(8, health.waterMlToday / 250))
                            .frame(maxWidth: .infinity, minHeight: 38)
                    }
                    .buttonStyle(.plain)
                    .disabled(health.waterSaving)
                }
            }
            // Eight identical glasses read as one control that reports progress.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Water")
            .accessibilityValue("\(min(8, health.waterMlToday / 250)) of 8 glasses, \(health.waterMlToday.formatted()) milliliters")
            .accessibilityHint("Adds 250 milliliters in Apple Health")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                guard !health.waterSaving else { return }
                Task { await health.logWaterCup() }
            }
            Text(health.waterRequested ? "Tap a glass to add 250 mL in Apple Health." :
                 "Tap a glass to connect Water in Apple Health and add 250 mL.")
                .font(.caption).foregroundStyle(.secondary)
            DelayedNotice(message: health.waterErrorMessage, isRefreshing: health.isRefreshing || health.isRefreshingWater) { error in
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var fiveADayCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("5 a day").font(.headline)
                Spacer()
                Text("\(store.fruitVegToday) of 5")
                    .font(.subheadline.weight(.semibold))
            }
            HStack(spacing: 12) {
                ForEach(0..<5, id: \.self) { index in
                    Image(systemName: "leaf.fill")
                        .font(.title3)
                        .foregroundStyle(index < store.fruitVegToday ? Color.green : Color.secondary.opacity(0.3))
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(store.fruitVegToday) of 5 fruit and vegetable portions today")
            Text("Based on the portions marked in your logged foods.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var foodLogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(selectedDayIsToday ? "Today’s food" : "Food log").font(.title3.bold())
                Spacer()
                Button { shiftLogDate(by: -1) } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44)
                }
                .disabled(selectedLogDate <= earliestLogDate)
                .accessibilityLabel("Previous day")
                Button { shiftLogDate(by: 1) } label: {
                    Image(systemName: "chevron.right").frame(width: 44, height: 44)
                }
                .disabled(selectedDayIsToday)
                .accessibilityLabel("Next day")
            }
            HStack {
                Text("Date")
                Spacer(minLength: 0)
                DatePicker("Food log date", selection: $selectedLogDate,
                           in: earliestLogDate...Date(), displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .accessibilityLabel("Food log date")
            }
            if !selectedDayIsToday {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        selectedDayMetrics
                        Spacer(minLength: 0)
                        selectedDayFeedbackAction
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        selectedDayMetrics
                        selectedDayFeedbackAction
                    }
                }
                if let selectedWaterError {
                    DelayedNotice(message: selectedWaterError) { error in
                        Text("Water from Apple Health: \(error)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if selectedWaterMl == nil && !health.waterRequested {
                    Text("Connect Apple Health to show water for past days.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if selectedLogs.isEmpty {
                Text("Nothing logged yet.").foregroundStyle(.secondary)
            }
            ForEach(selectedLogs) { log in
                HStack {
                    VStack(alignment: .leading) {
                        Text(log.foodName)
                        Text(log.quantity == 1 ? log.serving : "\(log.quantity.formatted()) × \(log.serving)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(log.kcal) kcal").font(.subheadline.monospacedDigit())
                    if log.countedFruitVegPortions > 0 {
                        Label("\(log.countedFruitVegPortions)", systemImage: "leaf.fill")
                            .font(.caption).foregroundStyle(.secondary).labelStyle(.tintedIcon(.green))
                    }
                    if deletingLogID == log.id { ProgressView() }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(logAccessibilityLabel(log))
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(log) }
                        .disabled(deletingLogID != nil)
                }
                .contextMenu {
                    Button("Delete log", role: .destructive) { delete(log) }
                        .disabled(deletingLogID != nil)
                }
            }
            if !selectedDayIsToday {
                Button {
                    backdatedLogDate = selectedLogDate
                    addLaunch = .log
                } label: {
                    Label("Add missing food", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Add food for \(selectedLogDate.formatted(date: .abbreviated, time: .omitted))")
                if store.canRequestUpdatedDailyFeedback(on: selectedLogDate) {
                    Button { requestSelectedReview(replaceExisting: true) } label: {
                        HStack {
                            if requestingSelectedFeedback { ProgressView() }
                            else { Image(systemName: "arrow.clockwise") }
                            Text("Request new review")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(requestingSelectedFeedback)
                }
            }
        }
    }

    private func logAccessibilityLabel(_ log: FoodLog) -> String {
        let serving = log.quantity == 1 ? log.serving : "\(log.quantity.formatted()) × \(log.serving)"
        var parts = [log.foodName, serving, "\(log.kcal) calories"]
        let portions = log.countedFruitVegPortions
        if portions > 0 { parts.append("\(portions) fruit and vegetable portion\(portions == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    private var selectedDayMetrics: some View {
        HStack(spacing: 12) {
            Text("\(selectedLogs.reduce(0) { $0 + $1.kcal }) kcal")
                .accessibilityLabel("\(selectedLogs.reduce(0) { $0 + $1.kcal }) calories logged")
            HStack(spacing: 3) {
                WaterGlassIcon(filled: true)
                    .scaleEffect(0.58)
                    .frame(width: 17, height: 20)
                if let selectedWaterMl, selectedWaterMl >= 2000 {
                    Image(systemName: "checkmark")
                } else {
                    Text(selectedWaterGlasses)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(selectedWaterAccessibilityLabel)
            HStack(spacing: 4) {
                Image(systemName: "leaf.fill").foregroundStyle(.green)
                if selectedFruitVegPortions >= 5 {
                    Image(systemName: "checkmark")
                } else {
                    Text("\(selectedFruitVegPortions)/5")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(selectedFruitVegPortions) of 5 fruit and vegetable portions")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var selectedDayFeedbackAction: some View {
        if let feedback = selectedFeedback {
            Button {
                showingSelectedFeedback = true
            } label: {
                Label(feedback.state == "ready" ? "Review" : "Review pending",
                      systemImage: feedback.state == "ready" ? "text.bubble" : "clock")
            }
            .font(.subheadline)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(feedback.state == "ready" ? "Read daily review" : "Daily review pending")
        } else if store.canRequestDailyFeedback(on: selectedLogDate) {
            Button {
                requestSelectedReview()
            } label: {
                if requestingSelectedFeedback { ProgressView() }
                else { Label("Request review", systemImage: "text.bubble") }
            }
            .font(.subheadline)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(requestingSelectedFeedback)
            .accessibilityLabel("Request a daily review for this day")
        }
    }

    private func requestSelectedReview(replaceExisting: Bool = false) {
        let date = selectedLogDate
        requestingSelectedFeedback = true
        Task {
            defer { requestingSelectedFeedback = false }
            do { _ = try await store.requestDailyFeedback(on: date, using: health, replaceExisting: replaceExisting) }
            catch { errorText = error.localizedDescription }
        }
    }

    private func shiftLogDate(by days: Int) {
        guard let date = Calendar.current.date(byAdding: .day, value: days, to: selectedLogDate) else { return }
        selectedLogDate = min(max(date, earliestLogDate), Calendar.current.startOfDay(for: Date()))
    }

    private func loadSelectedWater(on date: Date) async {
        let requestID = UUID()
        selectedWaterRequestID = requestID
        selectedWaterMl = nil
        selectedWaterError = nil
        guard !Calendar.current.isDateInToday(date) else { return }
        let requestedDay = FoodDates.localDate(for: date)
        do {
            let milliliters = try await health.waterMl(on: date)
            guard !Task.isCancelled, selectedWaterRequestID == requestID,
                  FoodDates.localDate(for: selectedLogDate) == requestedDay else { return }
            selectedWaterMl = milliliters
        } catch {
            guard !Task.isCancelled, selectedWaterRequestID == requestID,
                  FoodDates.localDate(for: selectedLogDate) == requestedDay else { return }
            selectedWaterError = error.localizedDescription
        }
    }

    private func delete(_ log: FoodLog) {
        guard deletingLogID == nil else { return }
        deletingLogID = log.id
        Task {
            defer { deletingLogID = nil }
            do { try await store.deleteLog(log) }
            catch { errorText = error.localizedDescription }
        }
    }
}
