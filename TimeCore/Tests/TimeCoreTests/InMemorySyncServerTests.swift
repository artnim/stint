import XCTest
@testable import TimeCore

final class InMemorySyncServerTests: XCTestCase {
    func testTokensDeliverOnlyNewerChangesAndLatestState() async throws {
        let server = InMemorySyncServer()
        let a = SyncRecord(type: "Client", name: "A", fields: ["name": .string("v1")])
        _ = try await server.save([a])
        let first = try await server.fetchChanges(since: nil)
        XCTAssertEqual(first.changed.map(\.name), ["A"]); XCTAssertNotNil(first.token)

        _ = try await server.save([SyncRecord(type: "Client", name: "A", fields: ["name": .string("v2")]),
                                   SyncRecord(type: "Client", name: "B", fields: [:])])
        try await server.delete([SyncRecordID(type: "Client", name: "B")])
        let second = try await server.fetchChanges(since: first.token)
        XCTAssertEqual(second.changed.map { $0.string("name") }, ["v2"])
        XCTAssertEqual(second.deleted, [SyncRecordID(type: "Client", name: "B")])
        let third = try await server.fetchChanges(since: second.token)
        XCTAssertEqual(third.changed, []); XCTAssertEqual(third.deleted, [])
    }

    func testDeleteOfUnknownIsIgnoredAndFailNextThrows() async throws {
        let server = InMemorySyncServer()
        try await server.delete([SyncRecordID(type: "Client", name: "nope")])
        await server.setFailNext(true)
        do { _ = try await server.fetchChanges(since: nil); XCTFail("expected failure") } catch {}
        _ = try await server.fetchChanges(since: nil)   // only the next call fails
    }

    // Change tags: a save carrying a stale or missing version is refused, as CloudKit's .ifServerRecordUnchanged does.
    func testStaleOrMissingVersionIsRefused() async throws {
        let server = InMemorySyncServer()
        let a = server.device(try AppDatabase.inMemory()), b = server.device(try AppDatabase.inMemory())
        let rec = SyncRecord(type: "Client", name: "u1", fields: ["name": .string("v1")])
        let first = try await a.save([rec])
        XCTAssertEqual(first[rec.id], .saved)                         // new recordName
        let blind = try await b.save([rec])
        XCTAssertEqual(blind[rec.id], .failed("server changed"))      // b never saw it: no version
        _ = try await b.fetchChanges(since: nil)                      // pull stores the current version
        let fresh = try await b.save([rec])
        XCTAssertEqual(fresh[rec.id], .saved)
        let stale = try await a.save([rec])
        XCTAssertEqual(stale[rec.id], .failed("server changed"))      // a's version is now behind
        try await b.delete([rec.id])
        let gone = try await a.save([rec])
        XCTAssertEqual(gone[rec.id], .notFound)
    }
}
