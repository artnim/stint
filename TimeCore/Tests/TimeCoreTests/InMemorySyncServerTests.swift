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
}
