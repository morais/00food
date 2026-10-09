import SwiftUI
import WidgetKit

private struct WatchBalanceEntry: TimelineEntry {
    let date: Date
    let state: WatchTransferState
    var balance: WatchSnapshot? { state.balance(at: date) }
}

private struct WatchBalanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchBalanceEntry { WatchBalanceEntry(date: Date(), state: WatchTransferState()) }
    func getSnapshot(in context: Context, completion: @escaping (WatchBalanceEntry) -> Void) { completion(entry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchBalanceEntry>) -> Void) {
        let now = Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now.addingTimeInterval(86400)
        completion(Timeline(entries: [entry(), WatchBalanceEntry(date: tomorrow, state: entry().state)],
                            policy: .after(now.addingTimeInterval(15 * 60))))
    }
    private func entry() -> WatchBalanceEntry {
        WatchBalanceEntry(date: Date(), state: (try? WatchDisk.load(WatchTransferState.self, name: "watch-state")) ?? WatchTransferState())
    }
}

private struct WatchBalanceWidgetView: View {
    let entry: WatchBalanceEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        Group {
            if let balance = entry.balance {
                let remaining = balance.allowanceKcal - balance.consumedKcal
                if family == .accessoryCircular {
                    VStack(spacing: 1) {
                        Image(systemName: "fork.knife").font(.caption2)
                        Text(abs(remaining).formatted()).font(.headline).minimumScaleFactor(0.5)
                        Text(remaining >= 0 ? "left" : "over").font(.caption2)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(abs(remaining).formatted()) kcal \(remaining >= 0 ? "left" : "over")").font(.headline)
                            Spacer(minLength: 0)
                        }
                        HStack {
                            Link(destination: URL(string: "zerozerofoodwatch://food")!) { Label("Log food", systemImage: "fork.knife") }
                            Spacer(minLength: 2)
                            Link(destination: URL(string: "zerozerofoodwatch://water")!) { Label("\(min(8, balance.waterMl / 250))/8", systemImage: "drop.fill") }
                        }.font(.caption)
                    }
                }
            } else {
                VStack(spacing: 3) {
                    Image(systemName: "fork.knife")
                    Text("Open 00Food").font(.caption)
                }
            }
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(URL(string: "zerozerofoodwatch://today"))
    }
}

@main struct FoodWatchWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FoodWatchBalance", provider: WatchBalanceProvider()) { WatchBalanceWidgetView(entry: $0) }
            .configurationDisplayName("00Food balance")
            .description("Calories left, plus quick access to food and water.")
            .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}
