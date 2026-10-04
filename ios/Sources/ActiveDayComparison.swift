import SwiftUI

struct ActiveDayComparison: View {
    @AppStorage("activeDayStartMinutes") private var startMinutes = 7 * 60
    @AppStorage("activeDayEndMinutes") private var endMinutes = 23 * 60

    let allowanceKcal: Int
    let eatenKcal: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let dayFraction = ActiveDayProgress.fraction(
                at: timeline.date, startMinutes: startMinutes, endMinutes: endMinutes
            )
            let foodRatio = Double(max(0, eatenKcal)) / Double(max(1, allowanceKcal))
            let foodFraction = min(1, foodRatio)
            let dayPercent = Int((dayFraction * 100).rounded())
            let foodPercent = Int((foodRatio * 100).rounded())

            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { geometry in
                    let inset: CGFloat = 10
                    let travel = max(0, geometry.size.width - 2 * inset)
                    ZStack(alignment: .topLeading) {
                        Capsule()
                            .fill(.quaternary)
                            .frame(height: 4)
                            .offset(y: 10)
                        Circle()
                            .fill(.regularMaterial)
                            .overlay(Circle().strokeBorder(.secondary, lineWidth: 2))
                            .frame(width: 20, height: 20)
                            .offset(x: travel * dayFraction)
                        Circle()
                            .fill(.tint)
                            .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                            .frame(width: 14, height: 14)
                            .offset(x: travel * foodFraction + 3, y: 3)
                    }
                }
                .frame(height: 20)
                HStack(spacing: 5) {
                    Circle().strokeBorder(.secondary, lineWidth: 2).frame(width: 10, height: 10)
                    Text("\(dayPercent)% active day")
                    Spacer(minLength: 8)
                    Circle().fill(.tint).frame(width: 10, height: 10)
                    Text("\(foodPercent)% allowance used")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint("The active-day marker uses the hours set in Settings. The food marker uses the base target plus Apple Health active calories earned so far.")
        }
    }
}
