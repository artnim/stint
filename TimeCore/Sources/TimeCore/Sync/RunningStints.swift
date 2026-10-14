import Foundation
import GRDB

extension Database {
    /// R7: after a merge at most one stint may run. The latest start keeps running; every other
    /// running entry ends at that start, or at its own start when that is later (zero length).
    /// Returns the number of stints ended. The changes are logged for push.
    public func resolveRunningStints(deviceId: String, now: Date) throws -> Int {
        let running = try Entry.filter(Column("endUTC") == nil && Column("deletedAt") == nil)
            .order(Column("startUTC").desc, Column("uuid").desc)
            .fetchAll(self)
        guard running.count > 1 else { return 0 }
        let keeper = running[0]
        for var e in running.dropFirst() {
            e.endUTC = max(e.startUTC, keeper.startUTC)
            try syncUpdate(&e, deviceId: deviceId, now: now)
        }
        return running.count - 1
    }
}

extension AppDatabase {
    public func resolveRunningStints() throws -> Int {
        try write { try $0.resolveRunningStints(deviceId: deviceId, now: Date()) }
    }
}
