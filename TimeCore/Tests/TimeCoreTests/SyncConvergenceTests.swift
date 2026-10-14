import XCTest
import GRDB
@testable import TimeCore

/// Random interleaved edits on two devices with random sync points end with identical data.
final class SyncConvergenceTests: XCTestCase {
    func testRandomOperationsConverge() async throws {
        var rng = SystemRandomNumberGenerator()
        let server = InMemorySyncServer()
        let a = try makeDevice(server), b = try makeDevice(server)
        let devices = [a, b]
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        var clock = t0
        for step in 0..<200 {
            let d = devices[Int.random(in: 0..<2, using: &rng)]
            clock = clock.addingTimeInterval(Double(Int.random(in: 1...120, using: &rng)))
            switch Int.random(in: 0..<7, using: &rng) {
            case 0: var c = Client(name: "c\(step)"); try d.db.insert(&c)
            case 1: let cl = try d.db.allClients(); var p = Project(clientId: cl.randomElement(using: &rng)?.id, name: "p\(step)"); try d.db.insert(&p)
            case 2: try d.db.start(description: "e\(step)", projectId: try d.db.allProjects().randomElement(using: &rng)?.id, at: clock)
            case 3: try d.db.stopRunning(at: clock)
            case 4: if var p = try d.db.allProjects().randomElement(using: &rng) { try edit(d.db, &p, at: clock) { $0.name = "p\(step)" } }
            case 5: if let e = try d.db.entries(from: t0, to: clock.addingTimeInterval(1)).randomElement(using: &rng) { try d.db.delete(e) }
            default: _ = try await d.engine.sync()
            }
        }
        for _ in 0..<3 { for d in devices { _ = try await d.engine.sync() } }

        func snapshot(_ db: AppDatabase) throws -> [String] {
            try db.read { db in
                var out: [String] = []
                for table in SyncTables.synced {
                    let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table) WHERE deletedAt IS NULL ORDER BY uuid")
                    for r in rows {
                        let cols = r.columnNames.filter { !["id", "projectId", "clientId", "repoId"].contains($0) }
                        out.append(table + ":" + cols.map { "\($0)=\(r[$0] as DatabaseValue)" }.joined(separator: ","))
                    }
                }
                return out
            }
        }
        XCTAssertEqual(try snapshot(a.db), try snapshot(b.db))
        XCTAssertLessThanOrEqual(try a.db.read { try Entry.filter(Column("endUTC") == nil && Column("deletedAt") == nil).fetchCount($0) }, 1)
        XCTAssertEqual(try a.db.pendingOutbox(), []); XCTAssertEqual(try b.db.pendingOutbox(), [])
    }
}
