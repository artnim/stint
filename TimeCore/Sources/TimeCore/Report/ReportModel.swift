import Foundation

public struct ReportOptions: Codable, Equatable {
    public var language: Language = .de
    public var title: String? = nil
    public var gridMinutes: Int = 15
    public var durationRounding: DurationRounding = .none
    public var startSnap: SnapMode = .nearest
    public var showTimes: Bool = true
    public var showIssue: Bool? = nil     // nil = auto
    public var showTags: Bool? = nil      // nil = auto
    public var maxTags: Int = 3
    public var tagChars: Int = 26
    public var summary: Bool = false
    public var newestFirst: Bool = false
    public init() {}
}

public enum ReportColumn: Equatable {
    case time, issue, description, tags, duration
}

public struct ReportDay: Equatable {
    public var day: Day
    public var label: String
    public var entries: [ReportEntry]
    public var totalHours: Double
}

public struct ReportMeta: Equatable {
    public var client: String
    public var project: String
    public var user: String
    public var period: String
    public init(client: String, project: String, user: String, period: String) {
        self.client = client; self.project = project; self.user = user; self.period = period
    }
}

public struct TagShare: Equatable {
    public var name: String
    public var hours: Double
    public init(name: String, hours: Double) { self.name = name; self.hours = hours }
}

public struct Report: Equatable {
    public var options: ReportOptions
    public var strings: Strings
    public var title: String
    public var meta: ReportMeta
    public var columns: [ReportColumn]
    public var days: [ReportDay]
    public var totalHours: Double
    public var entryCount: Int
    public var warnings: [String]
    public var tagSummary: [TagShare]
    public var calendar: Calendar
}

/// Port of the `main()` pipeline + `build_pdf()` grouping from solidtime_report.py.
/// `entries` must already be filtered (finished, in period, client/project).
public func buildReport(_ input: [ReportEntry], options o: ReportOptions, calendar: Calendar) -> Report? {
    guard !input.isEmpty else { return nil }
    let t = Strings.of(o.language)
    var entries = input

    if o.durationRounding != .none {
        for i in entries.indices {
            entries[i].hours = roundHours(entries[i].hours, minutes: o.gridMinutes, mode: o.durationRounding)
        }
    }
    for i in entries.indices {
        entries[i].start = snap(entries[i].rawStart, minutes: o.gridMinutes, mode: o.startSnap, calendar: calendar)
        entries[i].end = entries[i].start.addingTimeInterval(entries[i].hours * 3600)
    }
    let synthetic = o.durationRounding != .none
    resolveSnapCollisions(&entries, minutes: o.gridMinutes, mode: o.startSnap,
                          syntheticEnds: synthetic, calendar: calendar)
    // Like the Python script: raw ends are not inflated by in-script rounding, so sanity sees the truth.
    let warnings = sanityCheck(entries, minutes: o.gridMinutes, syntheticEnds: false, calendar: calendar)

    var columns: [ReportColumn] = []
    if o.showTimes { columns.append(.time) }
    let issueCount = entries.filter { !$0.issue.isEmpty }.count
    if o.showIssue ?? (issueCount >= max(3, entries.count / 4)) { columns.append(.issue) }
    columns.append(.description)
    if o.showTags ?? entries.contains(where: { !$0.tags.isEmpty }) { columns.append(.tags) }
    columns.append(.duration)

    let ordered = entries.sorted { o.newestFirst ? $0.rawStart > $1.rawStart : $0.rawStart < $1.rawStart }
    var dayOrder: [Day] = []
    var byDay: [Day: [ReportEntry]] = [:]
    for e in ordered {
        let d = e.day(in: calendar)
        if byDay[d] == nil { dayOrder.append(d) }
        byDay[d, default: []].append(e)
    }
    let days = dayOrder.map { d -> ReportDay in
        let group = byDay[d]!.sorted { o.newestFirst ? $0.start > $1.start : $0.start < $1.start }
        return ReportDay(day: d, label: fmtDate(d, o.language), entries: group,
                         totalHours: group.reduce(0) { $0 + $1.hours })
    }

    let total = entries.reduce(0) { $0 + $1.hours }
    let clients = Set(entries.map(\.client).filter { !$0.isEmpty }).sorted()
    let projects = Set(entries.map(\.project).filter { !$0.isEmpty }).sorted()
    let users = Set(entries.map(\.user).filter { !$0.isEmpty }).sorted()
    let sortedDays = dayOrder.sorted()
    let meta = ReportMeta(
        client: clients.count == 1 ? clients[0] : "\(t.several) (\(clients.count))",
        project: projects.count == 1 ? projects[0] : "\(t.several) (\(projects.count))",
        user: users.count <= 3 ? users.joined(separator: ", ") : "\(t.several) (\(users.count))",
        period: fmtPeriod(sortedDays.first!, sortedDays.last!, o.language))

    var tagSummary: [TagShare] = []
    if o.summary {
        var order: [String] = []
        var buckets: [String: Double] = [:]
        for e in entries {
            let keys = e.tags.isEmpty ? [t.noTag] : e.tags
            for k in keys {
                if buckets[k] == nil { order.append(k) }
                buckets[k, default: 0] += e.hours / Double(keys.count)
            }
        }
        tagSummary = order.map { TagShare(name: $0, hours: buckets[$0]!) }
            .sorted { $0.hours > $1.hours }   // stable: ties keep first-seen order
    }

    return Report(options: o, strings: t, title: o.title ?? t.title, meta: meta, columns: columns,
                  days: days, totalHours: total, entryCount: entries.count, warnings: warnings,
                  tagSummary: tagSummary, calendar: calendar)
}

/// Half-open [first day 00:00, first day of next month 00:00) in `calendar`'s time zone.
public func monthRange(year: Int, month: Int, calendar: Calendar) -> (start: Date, end: Date) {
    let start = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
    let end = calendar.date(byAdding: .month, value: 1, to: start)!
    return (start, end)
}
