import SwiftUI

struct RootView: View {
    @Environment(FoodStore.self) private var store
    @Environment(HealthEnergy.self) private var health
    @Environment(\.scenePhase) private var scenePhase
    @State private var errorText: String?

    var body: some View {
        Group {
            if !store.signedIn { SignInView() }
            else if store.profile == nil { ProfileView(isOnboarding: true) }
            else { HomeView() }
        }
        .task {
            if store.signedIn {
                do { try await store.refresh() } catch { errorText = error.localizedDescription }
                health.setHistoryStart(store.accountStartedAt)
                await health.refresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && store.signedIn {
                Task {
                    try? await store.refresh()
                    health.setHistoryStart(store.accountStartedAt)
                    await health.refresh()
                }
            }
        }
        .alert("Could not refresh", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }
}

struct HomeView: View {
    @Environment(FoodStore.self) private var store
    @Environment(HealthEnergy.self) private var health
    @State private var shortcuts = FoodQuickActions.shared
    @State private var addLaunch: FoodQuickLaunch?
    @State private var showingSettings = false
    @State private var showingProgress = false
    @State private var reviewing: PendingEstimation?
    @State private var errorText: String?
    @State private var deletingLogID: String?
    @State private var selectedLogDate = Calendar.current.startOfDay(for: Date())

    private var remaining: Int {
        (store.profile?.roughDailyTarget ?? 0) + health.activeKcal - store.consumedToday
    }
    private var selectedLogs: [FoodLog] { store.logs(on: selectedLogDate) }
    private var selectedDayIsToday: Bool { Calendar.current.isDateInToday(selectedLogDate) }
    private var earliestLogDate: Date {
        Calendar.current.date(byAdding: .day, value: -89, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    balanceCard
                    Button { addLaunch = .log } label: {
                        Label("Log food", systemImage: "plus.circle.fill")
                            .font(.headline).frame(maxWidth: .infinity).frame(height: 48)
                    }
                    .buttonStyle(.borderedProminent)

                    if !store.estimations.isEmpty { estimatesSection }
                    foodLogSection
                }
                .padding(.horizontal, 20).padding(.bottom, 28)
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
                QuickAddView(openCameraOnAppear: launch == .camera)
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $showingProgress) { ProgressPlansView() }
            .sheet(item: $reviewing) { ReviewEstimationView(estimation: $0) }
            .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
            .refreshable {
                try? await store.refresh()
                health.setHistoryStart(store.accountStartedAt)
                await health.refresh()
            }
            .task {
                health.setHistoryStart(store.accountStartedAt)
                await health.refresh()
            }
            .onAppear { openPendingShortcut() }
            .onChange(of: shortcuts.pendingLaunch) { _, _ in openPendingShortcut() }
        }
    }

    private func openPendingShortcut() {
        guard let launch = shortcuts.pendingLaunch else { return }
        shortcuts.pendingLaunch = nil
        let hasPresentedSheet = addLaunch != nil || showingSettings || showingProgress || reviewing != nil
        if hasPresentedSheet {
            addLaunch = nil
            showingSettings = false
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

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Today’s rough balance").font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(remaining)").font(.system(size: 48, weight: .bold, design: .rounded))
                Text("kcal left").font(.headline).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Label("\(store.consumedToday) eaten", systemImage: "fork.knife")
                Label("\(health.activeKcal) active", systemImage: "figure.walk")
            }
            .font(.subheadline)
            if let profile = store.profile {
                DayPaceGuide(baseKcal: profile.roughDailyTarget,
                             activeKcal: health.activeKcal,
                             eatenKcal: store.consumedToday,
                             logs: store.logs)
                if profile.restingKcal < 1200 {
                    Text("Resting estimate (\(profile.restingKcal) kcal); calorie gap (0 kcal). Minimum food target (1,200 kcal) + Health active energy − food.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Resting estimate (\(profile.restingKcal) kcal) − calorie gap (\(profile.effectiveDeficit(for: profile.deficitKcal)) kcal) + Health active energy − food.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !store.estimations.isEmpty {
                Label("\(store.estimations.count) \(store.estimations.count == 1 ? "food" : "foods") awaiting estimate or review · not counted yet",
                      systemImage: "clock")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
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

    private var estimatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Waiting for an estimate").font(.title3.bold())
            ForEach(store.estimations) { item in
                Button { if item.state == "proposed" { reviewing = item } else { showingSettings = true } } label: {
                    HStack {
                        Image(systemName: item.hasPhoto ? "photo" : "text.bubble")
                        VStack(alignment: .leading) {
                            Text(item.proposedName ?? (item.description.isEmpty ? "Food photo" : item.description))
                                .lineLimit(1).foregroundStyle(.primary)
                            Text(item.state == "proposed" ? "Review estimate" : "Ask your connected agent to estimate it")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    private var foodLogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(selectedDayIsToday ? "Today’s food" : "Food log").font(.title3.bold())
                Spacer()
                Button { shiftLogDate(by: -1) } label: {
                    Image(systemName: "chevron.left").frame(width: 30, height: 36)
                }
                .disabled(selectedLogDate <= earliestLogDate)
                .accessibilityLabel("Previous day")
                Button { shiftLogDate(by: 1) } label: {
                    Image(systemName: "chevron.right").frame(width: 30, height: 36)
                }
                .disabled(selectedDayIsToday)
                .accessibilityLabel("Next day")
            }
            DatePicker("Food log date", selection: $selectedLogDate,
                       in: earliestLogDate...Date(), displayedComponents: .date)
                .datePickerStyle(.compact)
            if !selectedDayIsToday {
                Text("\(selectedLogs.reduce(0) { $0 + $1.kcal }) kcal logged")
                    .font(.subheadline).foregroundStyle(.secondary)
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
                    if deletingLogID == log.id { ProgressView() }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(log) }
                        .disabled(deletingLogID != nil)
                }
                .contextMenu {
                    Button("Delete log", role: .destructive) { delete(log) }
                        .disabled(deletingLogID != nil)
                }
            }
        }
    }

    private func shiftLogDate(by days: Int) {
        guard let date = Calendar.current.date(byAdding: .day, value: days, to: selectedLogDate) else { return }
        selectedLogDate = min(max(date, earliestLogDate), Calendar.current.startOfDay(for: Date()))
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
