#if canImport(CloudKit)
import CloudKit
import Foundation
import GRDB

/// Production transport: one custom zone in the user's private database. Saves carry the stored change
/// tag (`.ifServerRecordUnchanged`) so a record deleted on the server is detected, not re-created;
/// last-writer-wins is decided by the stamps in the records.
private final class FetchAccumulator: @unchecked Sendable {
    var changed: [CKRecord] = []
    var deleted: [SyncRecordID] = []
    var token: CKServerChangeToken?
    var error: Error?
}

private final class SaveAccumulator: @unchecked Sendable {
    var out: [SyncRecordID: SyncSaveOutcome] = [:]
    var saved: [(String, Data)] = []
}

public final class CloudKitTransport: SyncTransport, @unchecked Sendable {
    public static let zoneName = "stint"
    static let boolFields: Set<String> = ["archived"]
    let container: CKContainer
    let database: CKDatabase
    let zoneID: CKRecordZone.ID
    private let appDatabase: AppDatabase
    private var prepared = false

    public init(containerIdentifier: String = "iCloud.io.artnim.stint", database appDatabase: AppDatabase) {
        self.appDatabase = appDatabase
        container = CKContainer(identifier: containerIdentifier)
        database = container.privateCloudDatabase
        zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    public func accountAvailable() async -> Bool {
        (try? await container.accountStatus()) == .available
    }

    /// Creates the zone and the change subscription once per process.
    public func prepare() async throws {
        guard !prepared else { return }
        _ = try await database.save(CKRecordZone(zoneID: zoneID))
        let sub = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: "stint-zone-changes")
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        do { _ = try await database.save(sub) } catch let e as CKError where e.code == .serverRejectedRequest {
            // already exists with the same ID
        }
        prepared = true
    }

    // MARK: SyncTransport

    public func fetchChanges(since token: String?) async throws -> SyncChanges {
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = try token.map(Self.decodeToken)
        let op = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID], configurationsByRecordZoneID: [zoneID: config])
        // The operation follows `moreComing` itself; these blocks fire for every page, so everything
        // is accumulated here and returned as one batch (R8: parents before children across pages).
        let acc = FetchAccumulator()
        op.recordWasChangedBlock = { _, result in
            switch result {
            case .success(let record): acc.changed.append(record)
            case .failure(let error): acc.error = acc.error ?? error
            }
        }
        op.recordWithIDWasDeletedBlock = { id, type in acc.deleted.append(SyncRecordID(type: type, name: id.recordName)) }
        op.recordZoneFetchResultBlock = { _, result in
            switch result {
            case .success(let r): acc.token = r.serverChangeToken
            case .failure(let error): acc.error = acc.error ?? error
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            op.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success: cont.resume()
                case .failure(let error): cont.resume(throwing: error)
                }
            }
            database.add(op)
        }
        // A record that failed to arrive must not let the token advance past it.
        if let error = acc.error { throw error }
        try writeMeta(store: acc.changed.map { ($0.recordID.recordName, Self.encodeSystemFields($0)) },
                      remove: acc.deleted.map(\.name))
        return SyncChanges(changed: acc.changed.map(Self.syncRecord(from:)), deleted: acc.deleted,
                           token: try acc.token.map(Self.encodeToken) ?? token)
    }

    public func save(_ records: [SyncRecord]) async throws -> [SyncRecordID: SyncSaveOutcome] {
        let stored = try readMeta(names: records.map(\.name))
        let ck = records.map { r -> CKRecord in
            if let data = stored[r.name], let base = Self.decodeSystemFields(data), base.recordType == r.type {
                return Self.apply(r, to: base)       // existing record: carries the change tag
            }
            return Self.ckRecord(from: r, zoneID: zoneID)   // new record
        }
        let op = CKModifyRecordsOperation(recordsToSave: ck, recordIDsToDelete: nil)
        // With the change tag, a record deleted on the server fails with .unknownItem instead of being re-created.
        op.savePolicy = .ifServerRecordUnchanged
        op.isAtomic = false
        let types = Dictionary(records.map { ($0.name, $0.type) }, uniquingKeysWith: { a, _ in a })
        let acc = SaveAccumulator()
        op.perRecordSaveBlock = { id, result in
            let key = SyncRecordID(type: types[id.recordName] ?? "", name: id.recordName)
            switch result {
            case .success(let record):
                acc.out[key] = .saved
                acc.saved.append((id.recordName, Self.encodeSystemFields(record)))
            case .failure(let error):
                acc.out[key] = Self.outcome(for: error)
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success: cont.resume()
                case .failure(let error):
                    if let e = error as? CKError, e.code == .partialFailure { cont.resume() } else { cont.resume(throwing: error) }
                }
            }
            database.add(op)
        }
        // A record the server reports as gone has no use for its stored tag.
        let gone = acc.out.filter { $0.value == .notFound }.map(\.key.name)
        try writeMeta(store: acc.saved, remove: gone)
        return acc.out
    }

    public func delete(_ ids: [SyncRecordID]) async throws {
        let op = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: ids.map { CKRecord.ID(recordName: $0.name, zoneID: zoneID) })
        op.isAtomic = false
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success: cont.resume()
                case .failure(let error):
                    if let e = error as? CKError, e.code == .partialFailure || e.code == .unknownItem { cont.resume() } else { cont.resume(throwing: error) }
                }
            }
            database.add(op)
        }
        try writeMeta(store: [], remove: ids.map(\.name))
    }

    static func outcome(for error: Error) -> SyncSaveOutcome {
        guard let e = error as? CKError else { return .failed(error.localizedDescription) }
        switch e.code {
        case .unknownItem: return .notFound
        case .serverRecordChanged: return .failed("server changed")   // next pull applies LWW; the row is re-pushed if ours wins
        default: return .failed(e.localizedDescription)
        }
    }

    // MARK: change-tag metadata (local table syncMeta, never synced)

    private func readMeta(names: [String]) throws -> [String: Data] {
        try appDatabase.read { db in
            var out: [String: Data] = [:]
            for name in names {
                if let data = try Data.fetchOne(db, sql: "SELECT systemFields FROM syncMeta WHERE recordName = ?", arguments: [name]) {
                    out[name] = data
                }
            }
            return out
        }
    }

    private func writeMeta(store: [(String, Data)], remove: [String]) throws {
        guard !store.isEmpty || !remove.isEmpty else { return }
        try appDatabase.write { db in
            for name in remove {
                try db.execute(sql: "DELETE FROM syncMeta WHERE recordName = ?", arguments: [name])
            }
            for (name, data) in store {
                try db.execute(sql: "INSERT OR REPLACE INTO syncMeta (recordName, systemFields) VALUES (?, ?)", arguments: [name, data])
            }
        }
    }

    static func encodeSystemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func decodeSystemFields(_ data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    // MARK: mapping

    // R13: `save` sets only the fields this client knows. A new record is built fresh; an existing one is
    // rebuilt from stored system fields, so unknown server fields are not sent. When a field is added in a
    // later version, `save` must fetch-then-modify so older clients' fields are not lost.
    static func ckRecord(from r: SyncRecord, zoneID: CKRecordZone.ID) -> CKRecord {
        apply(r, to: CKRecord(recordType: r.type, recordID: CKRecord.ID(recordName: r.name, zoneID: zoneID)))
    }

    static func apply(_ r: SyncRecord, to record: CKRecord) -> CKRecord {
        for (key, value) in r.fields {
            switch value {
            case .string(let s): record[key] = s as CKRecordValue
            case .int(let i): record[key] = i as CKRecordValue
            case .double(let d): record[key] = d as CKRecordValue
            case .bool(let b): record[key] = (b ? Int64(1) : Int64(0)) as CKRecordValue
            case .date(let d): record[key] = d as CKRecordValue
            case .strings(let l): record[key] = l as CKRecordValue
            case .null: record[key] = nil
            }
        }
        return record
    }

    static func syncRecord(from record: CKRecord) -> SyncRecord {
        var fields: [String: SyncValue] = [:]
        for key in record.allKeys() {
            switch record[key] {
            case let s as String: fields[key] = .string(s)
            case let d as Date: fields[key] = .date(d)
            case let l as [String]: fields[key] = .strings(l)
            case let n as NSNumber:
                if boolFields.contains(key) { fields[key] = .bool(n.boolValue) }
                else if CFNumberIsFloatType(n) { fields[key] = .double(n.doubleValue) }
                else { fields[key] = .int(n.int64Value) }
            default: break
            }
        }
        return SyncRecord(type: record.recordType, name: record.recordID.recordName, fields: fields)
    }

    static func encodeToken(_ token: CKServerChangeToken) throws -> String {
        try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true).base64EncodedString()
    }

    static func decodeToken(_ s: String) throws -> CKServerChangeToken {
        guard let data = Data(base64Encoded: s),
              let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data) else {
            throw CKError(.internalError)
        }
        return token
    }
}
#endif