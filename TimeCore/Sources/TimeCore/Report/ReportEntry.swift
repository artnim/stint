import Foundation

public struct Day: Hashable, Comparable, Codable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year; self.month = month; self.day = day
    }

    public init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    public func date(in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    public var isoString: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (a: Day, b: Day) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}

/// One line of the report. `raw*` is the truth (sorting, sanity checks);
/// `start`/`end` are the snapped, display-only times. Mirrors `Entry` in solidtime_report.py.
public struct ReportEntry: Equatable {
    public var description: String
    public var issue: String        // "#1234" or ""
    public var project: String
    public var client: String
    public var user: String
    public var rawStart: Date
    public var rawEnd: Date
    public var start: Date
    public var end: Date
    public var hours: Double
    public var tags: [String]

    static let issueRegex = #/(?s)^#(\d+)\s*[:\-–]?\s*(.*)$/#

    public init(description: String, project: String = "", client: String = "", user: String = "",
                start: Date, end: Date, hours: Double? = nil, tags: [String] = []) {
        var desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        var issue = ""
        if let m = try? Self.issueRegex.wholeMatch(in: desc) {
            issue = "#" + m.1
            desc = String(m.2).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        self.description = desc
        self.issue = issue
        self.project = project.trimmingCharacters(in: .whitespaces)
        self.client = client.trimmingCharacters(in: .whitespaces)
        self.user = user.trimmingCharacters(in: .whitespaces)
        self.rawStart = start
        self.rawEnd = end
        self.start = start
        self.end = end
        self.hours = hours ?? end.timeIntervalSince(start) / 3600
        self.tags = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public func day(in calendar: Calendar) -> Day {
        Day(rawStart, calendar: calendar)
    }
}
