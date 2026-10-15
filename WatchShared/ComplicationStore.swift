import Foundation

/// What the complication shows, written by the watch app after every write and sync, read by the widget.
enum ComplicationStore {
    static let suite = "group.io.artnim.stint"
    private static let key = "complication"

    struct Snapshot: Codable, Equatable {
        var description: String?
        var start: Date?
        static let idle = Snapshot(description: nil, start: nil)
    }

    static func save(_ s: Snapshot) {
        guard let d = UserDefaults(suiteName: suite), let data = try? JSONEncoder().encode(s) else { return }
        d.set(data, forKey: key)
    }

    static func load() -> Snapshot {
        guard let d = UserDefaults(suiteName: suite), let data = d.data(forKey: key),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return .idle }
        return s
    }
}
