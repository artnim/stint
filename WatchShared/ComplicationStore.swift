import Foundation

/// What the complication shows, written by the watch app after every write and sync, read by the widget.
enum ComplicationStore {
    static let suite = "group.io.artnim.stint"
    private static let key = "complication"
    private static let timelineKey = "complication.timeline"

    struct Snapshot: Codable, Equatable {
        var description: String?
        var start: Date?
        static let idle = Snapshot(description: nil, start: nil)
    }

    static func save(_ s: Snapshot) {
        guard let d = UserDefaults(suiteName: suite), let data = try? JSONEncoder().encode(s) else { return }
        d.set(data, forKey: key)
    }

    /// Diagnostic: the widget notes each timeline it builds, so the watch's Settings can show whether WidgetKit
    /// acted on a reload and what it read.
    static func noteTimeline(_ s: Snapshot) {
        UserDefaults(suiteName: suite)?.set("\(Date().formatted(date: .omitted, time: .standard)) (\(s.start == nil ? "idle" : "running"))",
                                            forKey: timelineKey)
    }

    static var timelineSummary: String {
        "Complication: timeline " + (UserDefaults(suiteName: suite)?.string(forKey: timelineKey) ?? "never built")
    }

    static func load() -> Snapshot {
        guard let d = UserDefaults(suiteName: suite), let data = d.data(forKey: key),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return .idle }
        return s
    }
}
