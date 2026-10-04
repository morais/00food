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
    @State private var showingAdd = false
    @State private var showingSettings = false
    @State private var showingProgress = false
    @State private var reviewing: PendingEstimation?
    @State private var errorText: String?
    @State private var loggingID: String?
    @State private var dismissingFoodID: String?
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
                    Button { showingAdd = true } label: {
                        Label("Log food", systemImage: "plus.circle.fill")
                            .font(.headline).frame(maxWidth: .infinity).frame(height: 48)
                    }
                    .buttonStyle(.borderedProminent)

                    if !store.estimations.isEmpty { estimatesSection }
                    recentSection
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
            .sheet(isPresented: $showingAdd) { QuickAddView() }
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
            Text("Resting estimate − calorie gap + Health active energy − food. Exercise minutes are not added again.")
                .font(.caption).foregroundStyle(.secondary)
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

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Frequent foods").font(.title3.bold())
                Spacer()
                Text("Tap to add one serving").font(.caption).foregroundStyle(.secondary)
            }
            if store.recentFoods.isEmpty {
                Text("Foods you log appear here for one-tap reuse. Hidden foods return when logged again.")
                    .foregroundStyle(.secondary).padding(.vertical, 10)
            }
            ForEach(Array(store.recentFoods.prefix(8))) { food in
                Button { log(food) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2).foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(food.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                            Text(food.serving).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(food.kcal)").font(.headline.monospacedDigit()).foregroundStyle(.primary)
                        if loggingID == food.id { ProgressView() }
                        if dismissingFoodID == food.id { ProgressView() }
                    }
                    .padding(.vertical, 8)
                }
                .disabled(loggingID != nil || dismissingFoodID != nil)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button("Hide", systemImage: "eye.slash") { dismiss(food) }
                        .tint(.gray)
                }
                .contextMenu {
                    Button("Log half serving") { log(food, quantity: 0.5) }
                    Button("Log two servings") { log(food, quantity: 2) }
                    Button("Hide from frequent foods") { dismiss(food) }
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

    private func log(_ food: FoodItem, quantity: Double = 1) {
        loggingID = food.id
        Task {
            defer { loggingID = nil }
            do { try await store.log(food, quantity: quantity) }
            catch { errorText = error.localizedDescription }
        }
    }

    private func dismiss(_ food: FoodItem) {
        guard dismissingFoodID == nil else { return }
        dismissingFoodID = food.id
        Task {
            defer { dismissingFoodID = nil }
            do { try await store.dismissFromFrequent(food) }
            catch { errorText = error.localizedDescription }
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
