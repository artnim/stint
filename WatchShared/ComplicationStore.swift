import Foundation

/// What the complication shows, written by the watch app after every write and sync and by the widget after its
/// own CloudKit check, read by the widget.
enum ComplicationStore {
    static let suite = "group.io.artnim.stint"
    private static let key = "complication"
    private static let timelineKey = "complication.timeline"
    private static let tokenKey = "complication.token"

    struct Snapshot: Codable, Equatable {
        var description: String?
        var start: Date?
        var uuid: String? = nil      // the running entry, so the widget can tell when it stops
        static let idle = Snapshot(description: nil, start: nil)
    }

    static func save(_ s: Snapshot) {
        guard let d = UserDefaults(suiteName: suite), let data = try? JSONEncoder().encode(s) else { return }
        d.set(data, forKey: key)
    }

    /// The zone change token the snapshot is current to: the app's after a sync, the widget's after its check.
    static var changeToken: String? {
        get { UserDefaults(suiteName: suite)?.string(forKey: tokenKey) }
        set { UserDefaults(suiteName: suite)?.set(newValue, forKey: tokenKey) }
    }

    /// Diagnostic: the widget notes each timeline it builds, so the watch's Settings can show whether WidgetKit
    /// acted on a reload, what it read and how its CloudKit check went.
    static func noteTimeline(_ s: Snapshot, check: String) {
        UserDefaults(suiteName: suite)?.set("\(Date().formatted(date: .omitted, time: .standard)) (\(s.start == nil ? "idle" : "running"), \(check))",
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
