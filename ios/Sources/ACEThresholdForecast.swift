import Foundation

enum ACEThresholdForecast {
    static func crossingDate(for threshold: Double, in points: [HealthMeasurePoint]) -> Date? {
        guard points.count > 1 else { return nil }
        for index in 1..<points.count {
            let before = points[index - 1]
            let after = points[index]
            guard before.value > threshold, after.value <= threshold else { continue }
            let fraction = (before.value - threshold) / (before.value - after.value)
            return before.date.addingTimeInterval(after.date.timeIntervalSince(before.date) * fraction)
        }
        return nil
    }
}
