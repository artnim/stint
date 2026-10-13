import Foundation
import TimeCore

struct ReportPreset: Codable, Identifiable, Equatable {
    var name: String
    var options: ReportOptions
    var id: String { name }

    /// The wrapper's defaults from solidtime-report: English, 15-min grid, durations up, starts ceil.
    static let monthly: ReportPreset = {
        var o = ReportOptions()
        o.language = .en
        o.title = "Timesheet {Month} {Year}"
        o.gridMinutes = 15
        o.durationRounding = .up
        o.startSnap = .ceil
        return ReportPreset(name: "Monthly timesheet", options: o)
    }()
}

enum PresetStore {
    static let key = "reportPresets"

    static func load(_ db: AppDatabase) -> [ReportPreset] {
        if let json = try? db.setting(key), let data = json.data(using: .utf8),
           let presets = try? JSONDecoder().decode([ReportPreset].self, from: data), !presets.isEmpty {
            return presets
        }
        return [.monthly]
    }

    static func save(_ presets: [ReportPreset], to db: AppDatabase) {
        if let data = try? JSONEncoder().encode(presets), let json = String(data: data, encoding: .utf8) {
            try? db.setSetting(key, json)
        }
    }
}
