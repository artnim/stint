import Foundation

public enum SnapMode: String, Codable, CaseIterable, Identifiable {
    case nearest, floor, ceil, none
    public var id: String { rawValue }
}

public enum DurationRounding: String, Codable, CaseIterable, Identifiable {
    case none, up, down, nearest
    public var id: String { rawValue }
}

/// Port of `snap()` from solidtime_report.py: move a wall-clock time onto the grid.
public func snap(_ date: Date, minutes: Int, mode: SnapMode, calendar: Calendar) -> Date {
    guard minutes > 0, mode != .none else { return date }
    let c = calendar.dateComponents([.minute, .second, .nanosecond], from: date)
    let second = c.second ?? 0
    let base = date.addingTimeInterval(-Double(second) - Double(c.nanosecond ?? 0) / 1e9)
    let off = (c.minute ?? 0) % minutes
    if off == 0 && second == 0 { return base }
    switch mode {
    case .floor:
        return base.addingTimeInterval(-Double(off * 60))
    case .ceil:
        return base.addingTimeInterval(Double((minutes - off) * 60))
    case .nearest, .none:
        let down = base.addingTimeInterval(-Double(off * 60))
        return off * 2 < minutes ? down : down.addingTimeInterval(Double(minutes * 60))
    }
}

/// Port of `round_hours()`: round a duration to a multiple of the grid.
public func roundHours(_ hours: Double, minutes: Int, mode: DurationRounding) -> Double {
    guard minutes > 0, mode != .none else { return hours }
    let step = Double(minutes) / 60.0
    let n = hours / step
    let k: Double
    switch mode {
    case .up: k = (n - 1e-9).rounded(.up)
    case .down: k = (n + 1e-9).rounded(.down)
    case .nearest, .none: k = (n + 0.5).rounded(.down)
    }
    return k * step
}
