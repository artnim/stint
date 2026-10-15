import Foundation

/// Rows <-> transport records. References travel as uuid strings; resolving them to local
/// ids is the engine's job, so `apply` never touches `projectId`/`clientId`/`repoId`.
enum RecordMapper {
    static let types = ["Client", "Project", "Repo", "Entry", "Setting", "AssignedIssues"]

    static func table(forType type: String) -> String? {
        switch type {
        case "Client": return "client"
        case "Project": return "project"
        case "Repo": return "repo"
        case "Entry": return "entry"
        case "Setting": return "setting"
        case "AssignedIssues": return "assignedIssues"
        default: return nil
        }
    }

    private static func stamps(_ modifiedAt: Date, _ modifiedBy: String) -> [String: SyncValue] {
        ["modifiedAt": .date(modifiedAt), "modifiedBy": .string(modifiedBy)]
    }
    private static func opt(_ s: String?) -> SyncValue { s.map { .string($0) } ?? .null }

    static func record(assignedIssues a: AssignedIssues) -> SyncRecord {
        SyncRecord(type: "AssignedIssues", name: a.uuid, fields: stamps(a.modifiedAt, a.modifiedBy).merging(
            ["fetchedAt": .date(a.fetchedAt), "payload": .string(a.payload)]) { $1 })
    }
    static func apply(_ r: SyncRecord, to a: inout AssignedIssues) {
        a.fetchedAt = r.date("fetchedAt") ?? a.fetchedAt
        a.payload = r.string("payload") ?? a.payload
        applyStamps(r, &a.modifiedAt, &a.modifiedBy)
    }

    static func record(client c: Client) -> SyncRecord {
        SyncRecord(type: "Client", name: c.uuid, fields: stamps(c.modifiedAt, c.modifiedBy).merging(
            ["name": .string(c.name), "archived": .bool(c.archived)]) { $1 })
    }

    static func record(project p: Project, clientUUID: String?) -> SyncRecord {
        SyncRecord(type: "Project", name: p.uuid, fields: stamps(p.modifiedAt, p.modifiedBy).merging(
            ["name": .string(p.name), "archived": .bool(p.archived), "clientUUID": opt(clientUUID)]) { $1 })
    }

    static func record(repo r: Repo, projectUUID: String?) -> SyncRecord {
        SyncRecord(type: "Repo", name: r.uuid, fields: stamps(r.modifiedAt, r.modifiedBy).merging(
            ["owner": .string(r.owner), "name": .string(r.name), "projectUUID": opt(projectUUID)]) { $1 })
    }

    static func record(entry e: Entry, projectUUID: String?, repoUUID: String?) -> SyncRecord {
        SyncRecord(type: "Entry", name: e.uuid, fields: stamps(e.modifiedAt, e.modifiedBy).merging([
            "startUTC": .date(e.startUTC),
            "endUTC": e.endUTC.map { .date($0) } ?? .null,
            "description": .string(e.description),
            "issueNumber": e.issueNumber.map { .int(Int64($0)) } ?? .null,
            "issueTitle": opt(e.issueTitle),
            "tags": .strings(e.tags),
            "importedKey": opt(e.importedKey),
            "projectUUID": opt(projectUUID),
            "repoUUID": opt(repoUUID),
        ]) { $1 })
    }

    static func record(settingKey key: String, value: String, modifiedAt: Date, modifiedBy: String) -> SyncRecord {
        SyncRecord(type: "Setting", name: key, fields: stamps(modifiedAt, modifiedBy).merging(["value": .string(value)]) { $1 })
    }

    static func apply(_ r: SyncRecord, to c: inout Client) {
        c.name = r.string("name") ?? c.name
        c.archived = r.bool("archived") ?? c.archived
        applyStamps(r, &c.modifiedAt, &c.modifiedBy)
    }
    static func apply(_ r: SyncRecord, to p: inout Project) {
        p.name = r.string("name") ?? p.name
        p.archived = r.bool("archived") ?? p.archived
        applyStamps(r, &p.modifiedAt, &p.modifiedBy)
    }
    static func apply(_ r: SyncRecord, to x: inout Repo) {
        x.owner = r.string("owner") ?? x.owner
        x.name = r.string("name") ?? x.name
        applyStamps(r, &x.modifiedAt, &x.modifiedBy)
    }
    static func apply(_ r: SyncRecord, to e: inout Entry) {
        e.startUTC = r.date("startUTC") ?? e.startUTC
        e.endUTC = r.date("endUTC")                       // .null -> nil: a running stint
        e.description = r.string("description") ?? e.description
        e.issueNumber = r.int("issueNumber").map(Int.init)
        e.issueTitle = r.string("issueTitle")
        e.tags = r.strings("tags") ?? []
        e.importedKey = r.string("importedKey")
        applyStamps(r, &e.modifiedAt, &e.modifiedBy)
    }
    private static func applyStamps(_ r: SyncRecord, _ at: inout Date, _ by: inout String) {
        at = r.date("modifiedAt") ?? at
        by = r.string("modifiedBy") ?? by
    }
}
