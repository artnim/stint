import XCTest
import GRDB
@testable import TimeCore

final class WindowTests: XCTestCase {
    func testWindowStartIsFirstDayOfMonthTwoBack() {
        XCTAssertEqual(windowStart(now: local("2026-10-14 12:00"), calendar: berlin), local("2026-08-01 00:00"))
        XCTAssertEqual(windowStart(now: local("2026-01-05 12:00"), calendar: berlin), local("2025-11-01 00:00"))
    }

    // Review Focus 4: pruning touches neither the outbox nor rows with pending changes.
    func testPruneDeletesOldFinishedEntriesWithoutLogging() throws {
        let db = try AppDatabase.inMemory()
        let cutoff = local("2026-08-01 00:00")
        try db.start(description: "old", projectId: nil, at: local("2026-07-10 09:00"))
        try db.stopRunning(at: local("2026-07-10 10:00"))
        try db.start(description: "new", projectId: nil, at: local("2026-08-10 09:00"))
        try db.stopRunning(at: local("2026-08-10 10:00"))
        // pretend everything was pushed, then edit one old entry so it is pending again
        try db.write { try $0.execute(sql: "DELETE FROM outbox") }
        try db.start(description: "old but edited", projectId: nil, at: local("2026-07-20 09:00"))
        try db.stopRunning(at: local("2026-07-20 10:00"))
        // inserted raw after the edit: start() would stop it and log that stop, and it must stay running
        try db.write { db in var e = Entry(description: "running since june", startUTC: local("2026-06-01 09:00")); try e.insert(db) }

        // every entry has a change tag, as after a pull
        try db.write { db in
            for uuid in try String.fetchAll(db, sql: "SELECT uuid FROM entry") {
                try db.execute(sql: "INSERT INTO syncMeta (recordName, systemFields) VALUES (?, ?)", arguments: [uuid, Data([1])])
            }
        }
        let oldUUID = try db.read { try String.fetchOne($0, sql: "SELECT uuid FROM entry WHERE description = 'old'") }!

        let pruned = try db.pruneEntries(startingBefore: cutoff)
        XCTAssertEqual(pruned, 1)
        let tags = try db.read { try String.fetchAll($0, sql: "SELECT recordName FROM syncMeta") }
        XCTAssertFalse(tags.contains(oldUUID), "the pruned entry's change tag goes with it")
        XCTAssertEqual(tags.count, 3, "the tags of the kept entries stay")
        let left = try db.entries(from: local("2026-01-01 00:00"), to: local("2026-12-31 00:00")).map(\.description)
        XCTAssertEqual(left.sorted(), ["new", "old but edited", "running since june"])
        XCTAssertEqual(try db.pendingOutbox().map(\.op), ["upsert", "upsert"], "unchanged: only the two pending upserts for the edited entry")
    }

    func testMonthTotalIncludesRunningStint() throws {
        let db = try AppDatabase.inMemory()
        let now = local("2026-10-14 12:00")
        try db.start(description: "last month", projectId: nil, at: local("2026-09-30 09:00"))
        try db.stopRunning(at: local("2026-09-30 10:00"))
        try db.start(description: "this month", projectId: nil, at: local("2026-10-02 09:00"))
        try db.stopRunning(at: local("2026-10-02 10:30"))
        try db.start(description: "running", projectId: nil, at: now.addingTimeInterval(-1800))
        XCTAssertEqual(try db.monthTotalHours(now: now, calendar: berlin), 2.0, accuracy: 1e-9)
    }

    // R17 / Review Focus 4: a one-month window prunes last month's finished entries only.
    func testOneMonthWindowKeepsRunningAndPending() throws {
        let db = try AppDatabase.inMemory()
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
        let lastMonth = cal.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 9))!
        try db.start(description: "september", projectId: nil, at: lastMonth)
        _ = try db.stopRunning(at: lastMonth.addingTimeInterval(3600))
        try db.start(description: "pending september", projectId: nil, at: lastMonth.addingTimeInterval(7200))
        _ = try db.stopRunning(at: lastMonth.addingTimeInterval(9000))
        try db.start(description: "october", projectId: nil, at: now.addingTimeInterval(-3600))
        _ = try db.stopRunning(at: now.addingTimeInterval(-1800))
        try db.start(description: "running since september", projectId: nil, at: lastMonth.addingTimeInterval(20000))
        // everything except "pending september" has been pushed
        try db.write { try $0.execute(sql: "DELETE FROM outbox WHERE uuid != (SELECT uuid FROM entry WHERE description = 'pending september')") }
        let cutoff = windowStart(now: now, months: 1, calendar: cal)
        XCTAssertEqual(cutoff, cal.date(from: DateComponents(year: 2026, month: 10, day: 1))!)
        XCTAssertEqual(try db.pruneEntries(startingBefore: cutoff), 1)
        let left = try db.entries(from: lastMonth, to: now.addingTimeInterval(86400)).map(\.description).sorted()
        XCTAssertEqual(left, ["october", "pending september", "running since september"])
    }
}
