import Foundation

/// Port of `resolve_snap_collisions()`. Snapping can push an entry's displayed start before
/// the previous entry's displayed end although the raw intervals never touched; nudge those
/// forward. Real overlaps stay visible unless `syntheticEnds` (durations were rounded, so the
/// displayed ends are inflated and overlaps are artifacts). Durations are never changed.
public func resolveSnapCollisions(_ entries: inout [ReportEntry], minutes: Int, mode: SnapMode,
                                  syntheticEnds: Bool, calendar: Calendar) {
    guard minutes > 0, mode != .none else { return }
    var byDay: [Day: [Int]] = [:]
    for (i, e) in entries.enumerated() {
        byDay[e.day(in: calendar), default: []].append(i)
    }
    for indices in byDay.values {
        let order = indices.sorted { entries[$0].rawStart < entries[$1].rawStart }
        for (p, c) in zip(order, order.dropFirst()) {
            let prev = entries[p]
            var cur = entries[c]
            let realOverlap = cur.rawStart < prev.rawEnd
            if cur.start < prev.end && (syntheticEnds || !realOverlap) {
                cur.start = snap(prev.end, minutes: minutes, mode: .ceil, calendar: calendar)
                cur.end = cur.start.addingTimeInterval(cur.hours * 3600)
                entries[c] = cur
            }
        }
    }
}
