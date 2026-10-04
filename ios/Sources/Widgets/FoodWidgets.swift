import AppIntents
import SwiftUI
import WidgetKit

private struct FoodBalanceEntry: TimelineEntry {
    let date: Date
    let snapshot: FoodWidgetSnapshot?
}

private struct FoodBalanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> FoodBalanceEntry {
        FoodBalanceEntry(date: .now, snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (FoodBalanceEntry) -> Void) {
        completion(FoodBalanceEntry(date: .now, snapshot: FoodWidgetSnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FoodBalanceEntry>) -> Void) {
        let now = Date()
        let snapshot = FoodWidgetSnapshotStore.load()
        let dates = (0..<16).compactMap { Calendar.current.date(byAdding: .minute, value: $0 * 30, to: now) }
        let entries = dates.map { FoodBalanceEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(8 * 60 * 60))))
    }
}

private struct FoodBalanceWidgetView: View {
    let entry: FoodBalanceEntry

    private let logURL = URL(string: "zerozerofood://log/food")!

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let snapshot = entry.snapshot, snapshot.isCurrent(at: entry.date) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(snapshot.remainingKcal)")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.7)
                    Text("kcal left").font(.subheadline).foregroundStyle(.white.opacity(0.7))
                    Spacer(minLength: 0)
                    Link(destination: logURL) {
                        Label("Log", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.white.opacity(0.16), in: Capsule())
                    }
                    .accessibilityLabel("Log food")
                }
                HStack(spacing: 14) {
                    Label("\(snapshot.consumedKcal) eaten", systemImage: "fork.knife")
                    Label("\(snapshot.activeKcal) active", systemImage: "figure.walk")
                    if snapshot.pendingCount > 0 {
                        Label("\(snapshot.pendingCount) pending", systemImage: "clock")
                    }
                }
                .font(.caption).foregroundStyle(.white.opacity(0.8))
                .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                progressLine(snapshot)
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("00Food").font(.title3.bold())
                        Text("Open the app to see today’s balance.")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    Link(destination: logURL) { Label("Log", systemImage: "plus") }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .containerBackground(Color(red: 0.08, green: 0.15, blue: 0.14), for: .widget)
    }

    private func progressLine(_ snapshot: FoodWidgetSnapshot) -> some View {
        let timeFraction = ActiveDayProgress.fraction(at: entry.date, startMinutes: snapshot.startMinutes,
                                                      endMinutes: snapshot.endMinutes)
        let foodRatio = Double(max(0, snapshot.consumedKcal)) / Double(max(1, snapshot.allowanceKcal))
        let foodFraction = min(1, foodRatio)
        return VStack(spacing: 6) {
            GeometryReader { geometry in
                let travel = max(0, geometry.size.width - 18)
                ZStack(alignment: .topLeading) {
                    Capsule().fill(.white.opacity(0.25)).frame(height: 3).offset(y: 8)
                    Circle().strokeBorder(.white.opacity(0.8), lineWidth: 2)
                        .frame(width: 18, height: 18).offset(x: travel * timeFraction)
                    Circle().fill(.mint).frame(width: 12, height: 12)
                        .offset(x: travel * foodFraction + 3, y: 3)
                }
            }
            .frame(height: 18)
            HStack(spacing: 5) {
                Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5).frame(width: 8, height: 8)
                Text("\(Int((timeFraction * 100).rounded()))% active day")
                Spacer(minLength: 5)
                Circle().fill(.mint).frame(width: 8, height: 8)
                Text("\(Int((foodRatio * 100).rounded()))% allowance used")
            }
            .font(.caption2).foregroundStyle(.white.opacity(0.72))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FoodBalanceWidget: Widget {
    let kind = FoodWidgetSnapshotStore.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FoodBalanceProvider()) { entry in
            FoodBalanceWidgetView(entry: entry)
        }
        .configurationDisplayName("00Food balance")
        .description("Today’s calories, active energy, and day pace, with a Log button.")
        .supportedFamilies([.systemMedium])
    }
}

private struct LogFoodControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.00food.control.log") {
            ControlWidgetButton(action: OpenFoodLogIntent(target: .log)) {
                Label("Log food", systemImage: "fork.knife")
            }
        }
        .displayName("Log food")
        .description("Open 00Food to log a meal.")
    }
}

private struct LogWithPhotoControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.00food.control.camera") {
            ControlWidgetButton(action: OpenFoodLogIntent(target: .camera)) {
                Label {
                    Text("Food photo")
                } icon: {
                    Image(systemName: "fork.knife")
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 9, weight: .bold))
                                .offset(x: 7, y: 5)
                        }
                }
            }
        }
        .displayName("Food photo")
        .description("Open 00Food and start the camera.")
    }
}

@main struct ZeroZeroFoodWidgetBundle: WidgetBundle {
    var body: some Widget {
        FoodBalanceWidget()
        LogFoodControl()
        LogWithPhotoControl()
    }
}
