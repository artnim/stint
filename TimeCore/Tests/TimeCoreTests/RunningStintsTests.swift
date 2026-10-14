import XCTest
@testable import TimeCore

final class RunningStintsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    // Review Focus 2: two offline starts converge on the later one; the earlier is booked up to it.
    func testTwoOfflineStartsConverge() async throws {
        let server = InMemorySyncServer()
        let a = try makeDevice(server), b = try makeDevice(server)
        try a.db.start(description: "on the mac", projectId: nil, at: t0)                       // 10:00
        try b.db.start(description: "on the phone", projectId: nil, at: t0.addingTimeInterval(1800))   // 10:30
        _ = try await a.engine.sync(); _ = try await b.engine.sync(); _ = try await a.engine.sync()
        for db in [a.db, b.db] {
            let running = try db.runningEntry()
            XCTAssertEqual(running?.description, "on the phone")
            let finished = try db.finishedEntries(from: t0, to: t0.addingTimeInterval(86400))
            XCTAssertEqual(finished.map(\.description), ["on the mac"])
            XCTAssertEqual(finished[0].endUTC, t0.addingTimeInterval(1800))
        }
        XCTAssertEqual(try a.db.pendingOutbox(), [], "the resolution was pushed")
    }

    func testLoserThatStartedAfterKeeperGetsZeroLength() throws {
        // can only happen with equal starts: both keep startUTC, the loser ends at its own start
        let db = try AppDatabase.inMemory()
        try db.write { db in
            var e1 = Entry(description: "a", startUTC: self.t0); try e1.insert(db)
            var e2 = Entry(description: "b", startUTC: self.t0); try e2.insert(db)
        }
        let ended = try db.resolveRunningStints()
        XCTAssertEqual(ended, 1)
        let entries = try db.entries(from: t0.addingTimeInterval(-1), to: t0.addingTimeInterval(1))
        XCTAssertEqual(entries.filter { $0.endUTC == nil }.count, 1)
        XCTAssertEqual(entries.first { $0.endUTC != nil }?.hours, 0)
    }

    func testSingleRunningIsUntouched() throws {
        let db = try AppDatabase.inMemory()
        try db.start(description: "x", projectId: nil, at: t0)
        XCTAssertEqual(try db.resolveRunningStints(), 0)
        XCTAssertNotNil(try db.runningEntry())
    }
}
