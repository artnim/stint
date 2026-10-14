import Foundation
import GRDB

/// First day of the month `months - 1` months before `now`'s month (3 → current month plus two).
public func windowStart(now: Date, months: Int = 3, calendar: Calendar) -> Date {
    let comps = calendar.dateComponents([.year, .month], from: now)
    let first = calendar.date(from: comps)!
    return calendar.date(byAdding: .month, value: -(months - 1), to: first)!
}

extension AppDatabase {
    /// R14: drop finished entries that start before `cutoff`, locally only. Never logs to the outbox
    /// and skips rows that still have pending changes, so nothing is lost on the way to the server.
    /// The pruned entries' change tags (`syncMeta`) go in the same transaction.
    @discardableResult
    public func pruneEntries(startingBefore cutoff: Date) throws -> Int {
        try write { db in
            let pending = Set(try String.fetchAll(db, sql: "SELECT uuid FROM outbox WHERE tableName = 'entry'"))
            let victims = try Entry.filter(Column("endUTC") != nil && Column("deletedAt") == nil && Column("startUTC") < cutoff)
                .fetchAll(db)
                .filter { !pending.contains($0.uuid) }
            for e in victims {
                _ = try e.delete(db)
                try db.execute(sql: "DELETE FROM syncMeta WHERE recordName = ?", arguments: [e.uuid])   // a returning row brings fresh tags
            }
            return victims.count
        }
    }

    /// R15: raw hours of this month's finished entries plus the running stint's elapsed time.
    public func monthTotalHours(now: Date, calendar: Calendar) throws -> Double {
        let comps = calendar.dateComponents([.year, .month], from: now)
        let (start, end) = monthRange(year: comps.year!, month: comps.month!, calendar: calendar)
        let finished = try finishedEntries(from: start, to: end).reduce(0.0) { $0 + ($1.hours ?? 0) }
        let running = try runningEntry().map { max(0, now.timeIntervalSince($0.startUTC)) / 3600 } ?? 0
        return finished + running
    }
}
