import CloudKit
import Foundation

/// The complication's own look at CloudKit. watchOS does not act on a timeline reload the app requests while in
/// the background (after a push), so each time WidgetKit rebuilds the timeline the widget fetches the zone changes
/// since the stored token and applies the ones that start or stop a stint. Mirrors the app's rules: an Entry
/// without `endUTC` is running, and of several running the latest start wins (R7).
enum CloudCheck {
    static func refreshed() async -> (snapshot: ComplicationStore.Snapshot, note: String) {
        let stored = ComplicationStore.load()
        guard let tokenString = ComplicationStore.changeToken, let data = Data(base64Encoded: tokenString),
              let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data) else {
            return (stored, "no token yet")
        }
        do {
            let (changed, deleted, newToken) = try await fetchChanges(since: token)
            var s = stored
            if let uuid = s.uuid,
               deleted.contains(uuid) || changed.contains(where: { $0.recordID.recordName == uuid && $0["endUTC"] != nil }) {
                s = .idle
            }
            let running = changed.filter { $0.recordType == "Entry" && $0["endUTC"] == nil }.compactMap { r -> ComplicationStore.Snapshot? in
                guard let start = r["startUTC"] as? Date else { return nil }
                return .init(description: r["description"] as? String, start: start, uuid: r.recordID.recordName)
            }
            if let latest = (running + [s]).filter({ $0.start != nil }).max(by: { $0.start! < $1.start! }) { s = latest }
            if s != stored { ComplicationStore.save(s) }
            if let newToken, let encoded = try? NSKeyedArchiver.archivedData(withRootObject: newToken, requiringSecureCoding: true) {
                ComplicationStore.changeToken = encoded.base64EncodedString()
            }
            return (s, "checked, \(changed.count + deleted.count) changes")
        } catch {
            return (stored, "check failed: \(error.localizedDescription)")
        }
    }

    private static func fetchChanges(since token: CKServerChangeToken) async throws -> ([CKRecord], Set<String>, CKServerChangeToken?) {
        let zoneID = CKRecordZone.ID(zoneName: "stint", ownerName: CKCurrentUserDefaultName)
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = token
        config.desiredKeys = ["startUTC", "endUTC", "description"]
        let op = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID], configurationsByRecordZoneID: [zoneID: config])
        op.configuration.timeoutIntervalForRequest = 10      // a widget gets little time
        var changed: [CKRecord] = []
        var deleted = Set<String>()
        var newToken: CKServerChangeToken?
        var failure: Error?
        op.recordWasChangedBlock = { _, result in
            switch result {
            case .success(let r): changed.append(r)
            case .failure(let e): failure = failure ?? e
            }
        }
        op.recordWithIDWasDeletedBlock = { id, _ in deleted.insert(id.recordName) }
        op.recordZoneFetchResultBlock = { _, result in
            switch result {
            case .success(let r): newToken = r.serverChangeToken
            case .failure(let e): failure = failure ?? e
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            op.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success: if let failure { cont.resume(throwing: failure) } else { cont.resume() }
                case .failure(let e): cont.resume(throwing: e)
                }
            }
            CKContainer(identifier: "iCloud.io.artnim.stint").privateCloudDatabase.add(op)
        }
        return (changed, deleted, newToken)
    }
}
