import XCTest
@testable import TimeCore

final class SyncRecordTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testEntryRoundTrip() {
        let e = Entry(projectId: 7, description: "#1: x", startUTC: t0, endUTC: t0.addingTimeInterval(900),
                      repoId: 3, issueNumber: 1, issueTitle: "x", tags: ["a", "b"],
                      uuid: "E1", modifiedAt: t0, modifiedBy: "dev-A")
        let r = RecordMapper.record(entry: e, projectUUID: "P1", repoUUID: "R1")
        XCTAssertEqual(r.type, "Entry"); XCTAssertEqual(r.name, "E1")
        XCTAssertEqual(r.string("projectUUID"), "P1"); XCTAssertEqual(r.string("repoUUID"), "R1")
        XCTAssertEqual(r.strings("tags"), ["a", "b"]); XCTAssertEqual(r.int("issueNumber"), 1)
        XCTAssertEqual(r.date("endUTC"), t0.addingTimeInterval(900)); XCTAssertEqual(r.string("modifiedBy"), "dev-A")

        var copy = Entry(description: "", startUTC: Date(), uuid: "E1")
        RecordMapper.apply(r, to: &copy)
        XCTAssertEqual(copy.description, "#1: x"); XCTAssertEqual(copy.tags, ["a", "b"])
        XCTAssertEqual(copy.endUTC, t0.addingTimeInterval(900)); XCTAssertEqual(copy.issueTitle, "x")
        XCTAssertEqual(copy.modifiedAt, t0); XCTAssertEqual(copy.modifiedBy, "dev-A")
        XCTAssertNil(copy.projectId, "references are resolved by the engine, not the mapper")
    }

    func testRunningEntryHasNullEnd() {
        let e = Entry(description: "run", startUTC: t0, uuid: "E2")
        let r = RecordMapper.record(entry: e, projectUUID: nil, repoUUID: nil)
        XCTAssertEqual(r.fields["endUTC"], .null)
        XCTAssertEqual(r.fields["projectUUID"], .null)
        var copy = Entry(description: "", startUTC: Date(), endUTC: t0, uuid: "E2")
        RecordMapper.apply(r, to: &copy)
        XCTAssertNil(copy.endUTC)
    }

    func testClientProjectRepoSettingRecords() {
        let c = RecordMapper.record(client: Client(name: "ACME", uuid: "C1", modifiedAt: t0, modifiedBy: "d"))
        XCTAssertEqual(c.type, "Client"); XCTAssertEqual(c.string("name"), "ACME"); XCTAssertEqual(c.bool("archived"), false)
        let p = RecordMapper.record(project: Project(clientId: 1, name: "Web", uuid: "P1"), clientUUID: "C1")
        XCTAssertEqual(p.string("clientUUID"), "C1")
        let r = RecordMapper.record(repo: Repo(projectId: 1, owner: "o", name: "r", uuid: "R1"), projectUUID: nil)
        XCTAssertEqual(r.fields["projectUUID"], .null); XCTAssertEqual(r.string("owner"), "o")
        let s = RecordMapper.record(settingKey: "userName", value: "M", modifiedAt: t0, modifiedBy: "d")
        XCTAssertEqual(s.type, "Setting"); XCTAssertEqual(s.name, "userName"); XCTAssertEqual(s.string("value"), "M")
        XCTAssertEqual(RecordMapper.table(forType: "Entry"), "entry")
    }

    func testCodableRoundTrip() throws {
        let r = SyncRecord(type: "Entry", name: "E", fields: ["a": .string("x"), "b": .date(t0), "c": .strings(["1"]), "d": .null, "e": .bool(true), "f": .int(3), "g": .double(1.5)])
        let data = try JSONEncoder().encode(r)
        XCTAssertEqual(try JSONDecoder().decode(SyncRecord.self, from: data), r)
    }
}
