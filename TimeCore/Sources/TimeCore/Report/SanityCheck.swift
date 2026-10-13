import Foundation

/// Port of `sanity_check()`: data smells in the raw data, as human-readable lines.
public func sanityCheck(_ entries: [ReportEntry], minutes: Int, syntheticEnds: Bool,
                        calendar: Calendar) -> [String] {
    var warn: [String] = []
    let hm = DateFormatter()
    hm.calendar = calendar
    hm.timeZone = calendar.timeZone
    hm.locale = Locale(identifier: "en_US_POSIX")
    hm.dateFormat = "HH:mm"

    var byDay: [Day: [ReportEntry]] = [:]
    for e in entries { byDay[e.day(in: calendar), default: []].append(e) }

    for day in byDay.keys.sorted() {
        let group = byDay[day]!
        var seen = Set<String>()
        for e in group {
            let key = "\(e.rawStart.timeIntervalSince1970)|\(e.description)|\(e.issue)"
            if seen.contains(key) {
                let desc = e.description.isEmpty ? "(no description)" : e.description
                warn.append("\(day.isoString)  duplicate: \(e.issue) \(desc) at \(hm.string(from: e.rawStart))")
            }
            seen.insert(key)
        }
        let ordered = group.sorted { $0.rawStart < $1.rawStart }
        for (prev, cur) in zip(ordered, ordered.dropFirst()) where cur.rawStart < prev.rawEnd {
            if syntheticEnds && prev.rawEnd.timeIntervalSince(cur.rawStart) < Double(minutes * 60) {
                continue
            }
            warn.append("\(day.isoString)  overlap: \(hm.string(from: prev.rawStart))-\(hm.string(from: prev.rawEnd)) "
                        + "and \(hm.string(from: cur.rawStart))-\(hm.string(from: cur.rawEnd))")
        }
    }

    if minutes > 0 {
        for e in entries {
            let mins = Int((e.hours * 60).rounded())
            let day = e.day(in: calendar).isoString
            if mins % minutes != 0 {
                warn.append("\(day)  duration \(mins) min is not a multiple of \(minutes) min: \(e.issue) \(e.description.prefix(40))")
            }
            if mins == 0 {
                warn.append("\(day)  zero-length entry: \(e.issue) \(e.description.prefix(40))")
            }
        }
    }

    for e in entries where e.description.isEmpty && e.issue.isEmpty {
        warn.append("\(e.day(in: calendar).isoString) \(hm.string(from: e.rawStart))  entry without description")
    }
    return warn
}
