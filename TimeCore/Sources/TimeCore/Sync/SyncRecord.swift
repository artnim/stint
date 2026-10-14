import Foundation

public enum SyncValue: Equatable, Codable, Sendable {
    case string(String), int(Int64), double(Double), bool(Bool), date(Date), strings([String]), null
}

public struct SyncRecordID: Hashable, Codable, Sendable {
    public var type: String
    public var name: String
    public init(type: String, name: String) { self.type = type; self.name = name }
}

/// Transport-neutral record: what CloudKit stores, what the in-memory server stores.
public struct SyncRecord: Equatable, Codable, Sendable {
    public var type: String
    public var name: String
    public var fields: [String: SyncValue]

    public init(type: String, name: String, fields: [String: SyncValue]) {
        self.type = type; self.name = name; self.fields = fields
    }
    public var id: SyncRecordID { SyncRecordID(type: type, name: name) }

    public func string(_ k: String) -> String? { if case .string(let v)? = fields[k] { return v }; return nil }
    public func int(_ k: String) -> Int64? { if case .int(let v)? = fields[k] { return v }; return nil }
    public func double(_ k: String) -> Double? { if case .double(let v)? = fields[k] { return v }; return nil }
    public func bool(_ k: String) -> Bool? { if case .bool(let v)? = fields[k] { return v }; return nil }
    public func date(_ k: String) -> Date? { if case .date(let v)? = fields[k] { return v }; return nil }
    public func strings(_ k: String) -> [String]? { if case .strings(let v)? = fields[k] { return v }; return nil }
}

public struct SyncChanges: Equatable, Sendable {
    public var changed: [SyncRecord]
    public var deleted: [SyncRecordID]
    public var token: String?
    public init(changed: [SyncRecord], deleted: [SyncRecordID], token: String?) {
        self.changed = changed; self.deleted = deleted; self.token = token
    }
}

/// `.notFound`: the server has deleted this record; do not re-create it.
public enum SyncSaveOutcome: Equatable, Sendable { case saved, notFound, failed(String) }

/// What the engine needs from a server. Saves are blind overwrites; LWW is decided by stamps.
public protocol SyncTransport: Sendable {
    func fetchChanges(since token: String?) async throws -> SyncChanges
    func save(_ records: [SyncRecord]) async throws -> [SyncRecordID: SyncSaveOutcome]
    func delete(_ ids: [SyncRecordID]) async throws
}
