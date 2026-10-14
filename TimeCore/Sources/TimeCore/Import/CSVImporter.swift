import CryptoKit
import Foundation
import GRDB

public struct CSVImportResult: Equatable {
    public var imported = 0
    public var skippedDuplicates = 0
    public var skippedBreaks = 0
    public var skippedUnfinished = 0
    public init(imported: Int = 0, skippedDuplicates: Int = 0, skippedBreaks: Int = 0, skippedUnfinished: Int = 0) {
        self.imported = imported; self.skippedDuplicates = skippedDuplicates
        self.skippedBreaks = skippedBreaks; self.skippedUnfinished = skippedUnfinished
    }
}

public enum CSVImportError: Error, Equatable {
    case empty
    case missingColumns([String])
}

/// One-time import of a solidtime "detailed" CSV export. Start/End are local wall-clock
/// times in `timeZone`; the "Duration (decimal)" column is ignored (duration = End − Start).
public struct CSVImporter {
    public let database: AppDatabase
    public let timeZone: TimeZone

    public init(database: AppDatabase, timeZone: TimeZone) {
        self.database = database
        self.timeZone = timeZone
    }

    public func importFile(at url: URL) throws -> CSVImportResult {
        try importText(String(contentsOf: url, encoding: .utf8))
    }

    public func importText(_ text: String) throws -> CSVImportResult {
        let rows = parseCSV(text)
        guard let header = rows.first, rows.count > 1 else { throw CSVImportError.empty }
        let col = Dictionary(header.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let missing = ["Description", "Start", "End"].filter { col[$0] == nil }.sorted()
        if !missing.isEmpty { throw CSVImportError.missingColumns(missing) }

        func cell(_ row: [String], _ name: String) -> String {
            guard let i = col[name], i < row.count else { return "" }
            return row[i].trimmingCharacters(in: .whitespaces)
        }

        var result = CSVImportResult()
        try database.write { db in
            var clientIds: [String: Int64] = [:]
            var projectIds: [String: Int64] = [:]   // "client\u{0}project"
            for c in try Client.fetchAll(db) { clientIds[c.name] = c.id }
            for p in try Project.fetchAll(db) {
                let cname = try p.clientId.flatMap { try Client.fetchOne(db, key: $0) }?.name ?? ""
                projectIds["\(cname)\u{0}\(p.name)"] = p.id
            }

            for row in rows.dropFirst() {
                if ["yes", "true", "1"].contains(cell(row, "Break").lowercased()) {
                    result.skippedBreaks += 1; continue
                }
                // The export's "Duration" (HH:MM:SS) is exact to the second and immune to DST changes;
                // the local timestamps are not (02:30 → 02:30 across the fall-back hour), so when the
                // column is present the end is start + duration rather than the parsed End.
                guard let start = parseLocal(cell(row, "Start")) else { result.skippedUnfinished += 1; continue }
                let end: Date
                if let secs = Self.seconds(fromDuration: cell(row, "Duration")), secs > 0 {
                    end = start.addingTimeInterval(secs)
                } else if let parsedEnd = parseLocal(cell(row, "End")), parsedEnd > start {
                    end = parsedEnd
                } else {
                    result.skippedUnfinished += 1; continue
                }
                var desc = cell(row, "Description")
                let task = cell(row, "Task")
                if !task.isEmpty && !desc.contains(task) {
                    desc = desc.isEmpty ? task : "\(desc) (\(task))"
                }
                let projectName = cell(row, "Project")
                let clientName = cell(row, "Client")
                let key = Self.key(start: start, end: end, description: desc, project: projectName)
                if try Entry.filter(Column("importedKey") == key).fetchCount(db) > 0 {
                    result.skippedDuplicates += 1; continue
                }

                var projectId: Int64? = nil
                if !projectName.isEmpty {
                    var clientId: Int64? = nil
                    if !clientName.isEmpty {
                        if let id = clientIds[clientName] { clientId = id } else {
                            var c = Client(name: clientName); try db.syncInsert(&c, deviceId: database.deviceId, now: Date())
                            clientIds[clientName] = c.id; clientId = c.id
                        }
                    }
                    let pkey = "\(clientName)\u{0}\(projectName)"
                    if let id = projectIds[pkey] { projectId = id } else {
                        var p = Project(clientId: clientId, name: projectName); try db.syncInsert(&p, deviceId: database.deviceId, now: Date())
                        projectIds[pkey] = p.id; projectId = p.id
                    }
                }
                let tags = cell(row, "Tags").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                var e = Entry(projectId: projectId, description: desc, startUTC: start, endUTC: end,
                              tags: tags, importedKey: key)
                try db.syncInsert(&e, deviceId: database.deviceId, now: Date())
                result.imported += 1
            }
        }
        return result
    }

    /// "HH:MM:SS" → seconds; nil for anything else (empty cell, decimal, garbage).
    static func seconds(fromDuration text: String) -> TimeInterval? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2]),
              (0..<60).contains(m), (0..<60).contains(s), h >= 0 else { return nil }
        return TimeInterval(h * 3600 + m * 60 + s)
    }

    static func key(start: Date, end: Date, description: String, project: String) -> String {
        let raw = "\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)|\(description)|\(project)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Parses a local wall-clock time in `timeZone`. Times inside a DST transition (the repeated
    /// autumn hour, the skipped spring hour) are resolved by DateFormatter without detection, so
    /// entries on those days may be off by an hour; accepted for a one-time import.
    private func parseLocal(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        let iso = ISO8601DateFormatter()
        return iso.date(from: s)
    }
}
