import Foundation

enum ActiveDayProgress {
    static func fraction(at date: Date, startMinutes: Int, endMinutes: Int) -> Double {
        let clock = Calendar.current.dateComponents([.hour, .minute], from: date)
        let minute = (clock.hour ?? 0) * 60 + (clock.minute ?? 0)
        let start = min(1439, max(0, startMinutes))
        let end = min(1439, max(0, endMinutes))

        if start == end { return Double((minute - start + 1440) % 1440) / 1440 }
        if start < end { return min(1, max(0, Double(minute - start) / Double(end - start))) }
        // A configured day may cross midnight. The marker stays at 100%
        // between its end and the next start.
        if minute >= end && minute < start { return 1 }
        let elapsed = minute >= start ? minute - start : minute + 1440 - start
        return min(1, Double(elapsed) / Double(end + 1440 - start))
    }
}
