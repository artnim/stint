import Foundation
import GRDB

public struct Client: Codable, Identifiable, Equatable, SyncableRecord {
    public static let databaseTableName = "client"
    public var id: Int64?
    public var name: String
    public var archived: Bool
    public var uuid: String
    public var modifiedAt: Date
    public var modifiedBy: String
    public var deletedAt: Date?

    public init(id: Int64? = nil, name: String, archived: Bool = false,
                uuid: String = UUID().uuidString, modifiedAt: Date = Date(), modifiedBy: String = "", deletedAt: Date? = nil) {
        self.id = id; self.name = name; self.archived = archived
        self.uuid = uuid; self.modifiedAt = modifiedAt; self.modifiedBy = modifiedBy; self.deletedAt = deletedAt
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct Project: Codable, Identifiable, Equatable, SyncableRecord {
    public static let databaseTableName = "project"
    public var id: Int64?
    public var clientId: Int64?
    public var name: String
    public var archived: Bool
    public var uuid: String
    public var modifiedAt: Date
    public var modifiedBy: String
    public var deletedAt: Date?

    public init(id: Int64? = nil, clientId: Int64?, name: String, archived: Bool = false,
                uuid: String = UUID().uuidString, modifiedAt: Date = Date(), modifiedBy: String = "", deletedAt: Date? = nil) {
        self.id = id; self.clientId = clientId; self.name = name; self.archived = archived
        self.uuid = uuid; self.modifiedAt = modifiedAt; self.modifiedBy = modifiedBy; self.deletedAt = deletedAt
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct Repo: Codable, Identifiable, Equatable, SyncableRecord {
    public static let databaseTableName = "repo"
    public var id: Int64?
    public var projectId: Int64?
    public var owner: String
    public var name: String
    public var uuid: String
    public var modifiedAt: Date
    public var modifiedBy: String
    public var deletedAt: Date?

    public var fullName: String { "\(owner)/\(name)" }

    public init(id: Int64? = nil, projectId: Int64? = nil, owner: String, name: String,
                uuid: String = UUID().uuidString, modifiedAt: Date = Date(), modifiedBy: String = "", deletedAt: Date? = nil) {
        self.id = id; self.projectId = projectId; self.owner = owner; self.name = name
        self.uuid = uuid; self.modifiedAt = modifiedAt; self.modifiedBy = modifiedBy; self.deletedAt = deletedAt
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct Entry: Codable, Identifiable, Equatable, SyncableRecord {
    public static let databaseTableName = "entry"
    public var id: Int64?
    public var projectId: Int64?
    public var startUTC: Date
    public var endUTC: Date?
    public var description: String
    public var repoId: Int64?
    public var issueNumber: Int?
    public var issueTitle: String?
    public var tags: [String]
    public var importedKey: String?
    public var uuid: String
    public var modifiedAt: Date
    public var modifiedBy: String
    public var deletedAt: Date?

    /// nil while the entry is running
    public var hours: Double? {
        guard let endUTC else { return nil }
        return endUTC.timeIntervalSince(startUTC) / 3600
    }

    public init(id: Int64? = nil, projectId: Int64? = nil, description: String, startUTC: Date,
                endUTC: Date? = nil, repoId: Int64? = nil, issueNumber: Int? = nil,
                issueTitle: String? = nil, tags: [String] = [], importedKey: String? = nil,
                uuid: String = UUID().uuidString, modifiedAt: Date = Date(), modifiedBy: String = "", deletedAt: Date? = nil) {
        self.id = id; self.projectId = projectId; self.description = description
        self.startUTC = startUTC; self.endUTC = endUTC; self.repoId = repoId
        self.issueNumber = issueNumber; self.issueTitle = issueTitle
        self.tags = tags; self.importedKey = importedKey
        self.uuid = uuid; self.modifiedAt = modifiedAt; self.modifiedBy = modifiedBy; self.deletedAt = deletedAt
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct IssueCache: Codable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "issueCache"
    public var id: Int64?
    public var repoId: Int64
    public var number: Int
    public var title: String
    public var isPullRequest: Bool
    public var state: String          // "open" | "closed"
    public var updatedAt: Date
    public var assignedToMe: Bool

    public init(id: Int64? = nil, repoId: Int64, number: Int, title: String,
                isPullRequest: Bool, state: String, updatedAt: Date, assignedToMe: Bool = true) {
        self.id = id; self.repoId = repoId; self.number = number; self.title = title
        self.isPullRequest = isPullRequest; self.state = state; self.updatedAt = updatedAt
        self.assignedToMe = assignedToMe
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct Setting: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "setting"
    public var key: String
    public var value: String
    public var modifiedAt: Date
    public var modifiedBy: String
    public var id: String { key }
    public init(key: String, value: String, modifiedAt: Date = Date(), modifiedBy: String = "") {
        self.key = key; self.value = value; self.modifiedAt = modifiedAt; self.modifiedBy = modifiedBy
    }
}
