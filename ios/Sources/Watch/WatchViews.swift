import SwiftUI

private enum WatchRoute: String, Hashable { case food, water, describe, estimates }

struct WatchHomeView: View {
    @Environment(WatchStore.self) private var store
    @State private var path: [WatchRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 12) {
                    TimelineView(.periodic(from: .now, by: 60)) { clock in
                        if let balance = store.state.balance(at: clock.date) {
                            WatchBalanceView(balance: balance, date: clock.date)
                        } else {
                            VStack(spacing: 8) {
                                Image(systemName: "fork.knife").font(.largeTitle).foregroundStyle(.blue)
                                Text(store.state.snapshot?.ready == true ? "Refresh today's balance" : "Welcome to 00Food")
                                    .font(.headline)
                                Text("Open 00Food on your iPhone to sync.").font(.caption).foregroundStyle(.secondary)
                                Button("Refresh") { store.refresh() }.buttonStyle(.bordered)
                            }
                        }
                    }
                    NavigationLink(value: WatchRoute.food) {
                        Label("Log food", systemImage: "fork.knife.circle.fill")
                    }
                    .buttonStyle(.borderedProminent).tint(.blue).disabled(store.state.snapshot?.ready != true)
                    NavigationLink(value: WatchRoute.water) {
                        Label("Water", systemImage: "drop.fill")
                    }
                    .buttonStyle(.bordered).disabled(store.state.snapshot?.ready != true)
                    if !(store.state.snapshot?.estimates.isEmpty ?? true) || store.state.commands.contains(where: { $0.kind == .estimate }) {
                        NavigationLink(value: WatchRoute.estimates) { Label("Food estimates", systemImage: "sparkles") }
                            .buttonStyle(.bordered)
                    }
                    if store.pendingCount > 0 {
                        Text("\(store.pendingCount) waiting to sync").font(.caption2).foregroundStyle(.secondary)
                    } else if let date = store.state.snapshot?.updatedAt, date != .distantPast {
                        Text("Updated \(date, style: .relative) ago").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 6)
            }
            .navigationTitle("00Food")
            .navigationDestination(for: WatchRoute.self) { route in
                switch route {
                case .food: WatchFoodsView()
                case .water: WatchWaterView()
                case .describe: WatchDescribeView()
                case .estimates: WatchEstimatesView()
                }
            }
            .onOpenURL { url in
                if let route = url.host.flatMap(WatchRoute.init(rawValue:)) { path = [route] }
                else { path = [] }
            }
        }
        .safeAreaInset(edge: .bottom) { WatchConfirmationView() }
        .alert("Could not save", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}

private struct WatchBalanceView: View {
    let balance: WatchSnapshot
    let date: Date

    var body: some View {
        let allowance = balance.targetKcal + balance.activeKcal
        let remaining = allowance - balance.consumedKcal
        let day = ActiveDayProgress.fraction(at: date, startMinutes: balance.startMinutes, endMinutes: balance.endMinutes)
        let food = Double(balance.consumedKcal) / Double(max(1, allowance))
        let color: Color = !balance.allowanceReady ? .gray : food > day ? .orange : .blue
        VStack(alignment: .leading, spacing: 8) {
            Text(abs(remaining).formatted()).font(.system(size: 44, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.6).lineLimit(1)
            Text(remaining >= 0 ? "kcal left" : "kcal over").font(.caption).foregroundStyle(.secondary)
            HStack {
                Label(balance.consumedKcal.formatted(), systemImage: "fork.knife")
                Spacer(minLength: 4)
                Label(balance.activeKcal.formatted(), systemImage: "figure.walk")
            }.font(.caption2).foregroundStyle(.secondary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 3)
                    Circle().fill(.background).overlay(Circle().stroke(.secondary, lineWidth: 2))
                        .frame(width: 13, height: 13).offset(x: max(0, proxy.size.width - 13) * day)
                    Circle().fill(color).overlay(Circle().stroke(.background, lineWidth: 1))
                        .frame(width: 9, height: 9).offset(x: max(0, proxy.size.width - 13) * min(1, food) + 2)
                }
            }.frame(height: 14)
            HStack {
                Text("Day \(Int((day * 100).rounded()))%")
                Spacer(minLength: 2)
                Text(balance.allowanceReady ? "Food \(Int((food * 100).rounded()))%" : "Updating…").foregroundStyle(color)
            }.font(.caption2)
            HStack {
                Label("\(min(8, balance.waterMl / 250))/8", systemImage: "drop.fill").foregroundStyle(.blue)
                Spacer()
                Label(balance.fruitVegPortions >= 5 ? "✓" : "\(balance.fruitVegPortions)/5", systemImage: "leaf.fill").foregroundStyle(.green)
            }.font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WatchFoodsView: View {
    @Environment(WatchStore.self) private var store
    @State private var query = ""
    @State private var quantityFood: FoodItem?
    private var foods: [FoodItem] {
        (store.state.snapshot?.foods ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            NavigationLink(value: WatchRoute.describe) { Label("Describe food", systemImage: "mic.fill") }
            if foods.isEmpty {
                Text(query.isEmpty ? "Your saved foods will appear here after syncing with your iPhone." : "No matching foods. Describe it to your agent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(foods) { food in
                HStack(spacing: 4) {
                    Button { store.log(food) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(food.name).font(.headline).foregroundStyle(.primary)
                            Text("\(food.kcal) kcal · \(food.serving)").font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    Button { quantityFood = food } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(.borderless).accessibilityLabel("Change portion for \(food.name)")
                }.padding(.vertical, 4)
            }
        }
        .searchable(text: $query, prompt: "Find food")
        .navigationTitle("Your foods")
        .sheet(item: $quantityFood) { food in WatchQuantityView(food: food) }
    }
}

private struct WatchQuantityView: View {
    let food: FoodItem
    @Environment(WatchStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var quantity = 1.0
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text(food.name).font(.headline)
                Text(food.serving).font(.caption).foregroundStyle(.secondary)
                Stepper(value: $quantity, in: 0.5...10, step: 0.5) { Text("\(quantity.formatted()) portions") }
                Text("\(Int((Double(food.kcal) * quantity).rounded())) kcal").font(.title3)
                Button("Log food") { store.log(food, quantity: quantity); dismiss() }.buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct WatchWaterView: View {
    @Environment(WatchStore.self) private var store
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { clock in
            let ml = store.state.balance(at: clock.date)?.waterMl ?? 0
            ScrollView {
                VStack(spacing: 14) {
                    WatchDrinkingGlass().frame(width: 42, height: 58).foregroundStyle(.blue)
                    Text("\(ml.formatted()) mL").font(.title2.bold())
                    HStack(spacing: 5) {
                        ForEach(0..<8) { index in
                            Capsule().fill(index < min(8, ml / 250) ? Color.blue : Color.gray.opacity(0.3))
                                .frame(height: 12)
                        }
                    }
                    .accessibilityLabel("\(min(8, ml / 250)) of 8 glasses")
                    Button { store.addWater() } label: { Label("250 mL", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Text("Saved to Apple Health through your iPhone.").font(.caption2).foregroundStyle(.secondary)
                }.padding(.horizontal, 4)
            }
        }.navigationTitle("Water")
    }
}

private struct WatchDrinkingGlass: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX + 2, y: rect.minY + 2))
            path.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.minY + 2))
            path.addLine(to: CGPoint(x: rect.maxX * 0.8, y: rect.maxY - 2))
            path.addLine(to: CGPoint(x: rect.maxX * 0.2, y: rect.maxY - 2))
            path.closeSubpath()
        }.strokedPath(StrokeStyle(lineWidth: 3, lineJoin: .round))
    }
}

private struct WatchDescribeView: View {
    @Environment(WatchStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    private var text: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Describe food & portion", text: $description)
                if !text.isEmpty { Text(text).font(.caption) }
                Button { store.estimate(text); if store.errorMessage == nil { dismiss() } } label: {
                    Label("Ask my agent", systemImage: "sparkles")
                }.buttonStyle(.borderedProminent).disabled(text.isEmpty || text.count > 2000)
                Text("Use the microphone in text entry to dictate. Review the estimate on your iPhone before logging.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.navigationTitle("New food")
    }
}

private struct WatchEstimatesView: View {
    @Environment(WatchStore.self) private var store
    var body: some View {
        List {
            ForEach(store.state.snapshot?.estimates ?? []) { estimate in
                VStack(alignment: .leading, spacing: 4) {
                    Text(estimate.name).font(.headline)
                    Label(estimate.state == "proposed" ? "Review on iPhone" : "Waiting for agent",
                          systemImage: estimate.state == "proposed" ? "checkmark.circle.fill" : "clock")
                        .font(.caption2).foregroundStyle(estimate.state == "proposed" ? .blue : .orange)
                }
            }
            ForEach(store.state.commands.filter { command in command.kind == .estimate &&
                !(store.state.snapshot?.estimates.contains(where: { $0.id == command.id }) ?? false) }) { command in
                VStack(alignment: .leading) {
                    Text(command.description ?? "New food").font(.headline)
                    Label("Waiting to sync", systemImage: "arrow.triangle.2.circlepath").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Button("Refresh") { store.refresh() }
        }.navigationTitle("Food estimates")
            .task { store.refresh() }
    }
}

private struct WatchConfirmationView: View {
    @Environment(WatchStore.self) private var store
    var body: some View {
        Group {
            if let command = store.confirmation {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(command.kind == .water ? "+250 mL" : command.kind == .food ? "Logged" : command.kind == .undo ? "Undone" : "Request saved")
                        .font(.caption).lineLimit(1)
                    if command.kind != .undo { Button("Undo") { store.undo() }.font(.caption).buttonStyle(.bordered) }
                }
                .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .task(id: command.id) {
                    try? await Task.sleep(for: .seconds(5))
                    if !Task.isCancelled && store.confirmation?.id == command.id { store.confirmation = nil }
                }
            }
        }
    }
}
