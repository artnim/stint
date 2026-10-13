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
                guard let start = parseLocal(cell(row, "Start")), let end = parseLocal(cell(row, "End")) else {
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
                            var c = Client(name: clientName); try c.insert(db)
                            clientIds[clientName] = c.id; clientId = c.id
                        }
                    }
                    let pkey = "\(clientName)\u{0}\(projectName)"
                    if let id = projectIds[pkey] { projectId = id } else {
                        var p = Project(clientId: clientId, name: projectName); try p.insert(db)
                        projectIds[pkey] = p.id; projectId = p.id
                    }
                }
                let tags = cell(row, "Tags").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                var e = Entry(projectId: projectId, description: desc, startUTC: start, endUTC: end,
                              tags: tags, importedKey: key)
                try e.insert(db)
                result.imported += 1
            }
        }
        return result
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
