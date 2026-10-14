import XCTest
import GRDB
@testable import TimeCore

final class SyncEngineTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    var server: InMemorySyncServer!
    var a: (db: AppDatabase, engine: SyncEngine)!
    var b: (db: AppDatabase, engine: SyncEngine)!

    override func setUpWithError() throws {
        server = InMemorySyncServer()
        a = try makeDevice(server)
        b = try makeDevice(server)
    }

    private func seedA() throws -> (Client, Project, Repo, Entry) {
        var c = Client(name: "ACME"); try a.db.insert(&c)
        var p = Project(clientId: c.id, name: "Web"); try a.db.insert(&p)
        let r = try a.db.addRepo(fullName: "acme/web")
        try a.db.assignRepo(r.id!, toProject: p.id)
        try a.db.start(description: "#1: login", projectId: p.id, repoId: r.id, issueNumber: 1, tags: ["x"], at: t0)
        let e = try a.db.stopRunning(at: t0.addingTimeInterval(1800))!
        return (c, p, try a.db.allRepos()[0], e)
    }

    // R1, R2, R6, R12: everything created on A appears on B with references resolved and the outbox drained.
    func testInsertsFlowAcrossDevices() async throws {
        let (c, p, r, e) = try seedA()
        let s1 = try await a.engine.sync()
        XCTAssertEqual(s1.pushed, 4)
        XCTAssertEqual(try a.db.pendingOutbox(), [])
        let s2 = try await b.engine.sync()
        XCTAssertEqual(s2.pulled, 4)
        let bc = try b.db.allClients()[0], bp = try b.db.allProjects()[0], br = try b.db.allRepos()[0]
        let be = try b.db.finishedEntries(from: t0, to: t0.addingTimeInterval(86400))[0]
        XCTAssertEqual(bc.uuid, c.uuid); XCTAssertEqual(bp.uuid, p.uuid); XCTAssertEqual(br.uuid, r.uuid); XCTAssertEqual(be.uuid, e.uuid)
        XCTAssertEqual(bp.clientId, bc.id); XCTAssertEqual(br.projectId, bp.id)
        XCTAssertEqual(be.projectId, bp.id); XCTAssertEqual(be.repoId, br.id)
        XCTAssertEqual(be.tags, ["x"]); XCTAssertEqual(be.modifiedBy, a.db.deviceId)
        XCTAssertEqual(try b.db.pendingOutbox(), [], "remote-applied rows are not logged")
    }

    // R3: the later stamp wins regardless of sync order.
    func testLaterEditWins() async throws {
        var (_, p, _, _) = try seedA()
        _ = try await a.engine.sync(); _ = try await b.engine.sync()
        var pb = try b.db.allProjects()[0]
        try edit(b.db, &pb, at: t0.addingTimeInterval(20)) { $0.name = "from B" }
        try edit(a.db, &p, at: t0.addingTimeInterval(10)) { $0.name = "from A" }
        _ = try await b.engine.sync(); _ = try await a.engine.sync(); _ = try await b.engine.sync()
        XCTAssertEqual(try a.db.allProjects()[0].name, "from B")
        XCTAssertEqual(try b.db.allProjects()[0].name, "from B")

        // the other order: A is later this time, and A pushes last
        try edit(b.db, &pb, at: t0.addingTimeInterval(30)) { $0.name = "B again" }
        try edit(a.db, &p, at: t0.addingTimeInterval(40)) { $0.name = "A again" }
        _ = try await b.engine.sync(); _ = try await a.engine.sync(); _ = try await b.engine.sync()
        XCTAssertEqual(try a.db.allProjects()[0].name, "A again")
        XCTAssertEqual(try b.db.allProjects()[0].name, "A again")
    }

    // R3 tie-break: equal stamps, the higher device id wins on both sides.
    func testTieBreakByDeviceId() async throws {
        var (_, p, _, _) = try seedA()
        _ = try await a.engine.sync(); _ = try await b.engine.sync()
        var pb = try b.db.allProjects()[0]
        let t = Date().addingTimeInterval(3600)   // edits must be newer than the real-clock seed stamps
        try edit(a.db, &p, at: t) { $0.name = "A" }
        try edit(b.db, &pb, at: t) { $0.name = "B" }
        _ = try await a.engine.sync(); _ = try await b.engine.sync(); _ = try await a.engine.sync()
        let winner = a.db.deviceId > b.db.deviceId ? "A" : "B"
        XCTAssertEqual(try a.db.allProjects()[0].name, winner)
        XCTAssertEqual(try b.db.allProjects()[0].name, winner)
    }

    // Stamps within a millisecond are equal (GRDB text vs CloudKit floating Dates): the tie-break decides.
    func testSubMillisecondDifferenceIsATie() {
        let local = t0, remote = t0.addingTimeInterval(0.0001)
        XCTAssertTrue(SyncEngine.localWins(local, "b", remote, "a"))
        XCTAssertFalse(SyncEngine.localWins(local, "a", remote, "b"))
        XCTAssertFalse(SyncEngine.localWins(local, "a", t0.addingTimeInterval(0.002), "a"))
    }

    // R4: a deletion on A beats a later edit on B.
    func testRemoteDeleteBeatsLocalEdit() async throws {
        let (_, _, _, e) = try seedA()
        _ = try await a.engine.sync(); _ = try await b.engine.sync()
        var eb = try b.db.finishedEntries(from: t0, to: t0.addingTimeInterval(86400))[0]
        try tombstone(a.db, e, at: t0.addingTimeInterval(10))
        try edit(b.db, &eb, at: t0.addingTimeInterval(20)) { $0.description = "edited after delete" }
        _ = try await a.engine.sync()                      // deletion reaches the server
        _ = try await b.engine.sync()                      // B pulls the deletion before pushing its edit
        XCTAssertEqual(try b.db.finishedEntries(from: t0, to: t0.addingTimeInterval(86400)), [])
        XCTAssertEqual(try a.db.finishedEntries(from: t0, to: t0.addingTimeInterval(86400)), [])
        let names = await server.records().keys.map(\.name)
        XCTAssertFalse(names.contains(e.uuid))
    }

    // R4: a local pending deletion survives an incoming edit.
    func testLocalDeleteBeatsRemoteEdit() async throws {
        let (_, _, _, e) = try seedA()
        _ = try await a.engine.sync(); _ = try await b.engine.sync()
        var eb = try b.db.finishedEntries(from: t0, to: t0.addingTimeInterval(86400))[0]
        try edit(b.db, &eb, at: t0.addingTimeInterval(20)) { $0.description = "edit" }
        _ = try await b.engine.sync()                      // edit is on the server
        try tombstone(a.db, e, at: t0.addingTimeInterval(10))   // A deletes offline, with an older stamp
        _ = try await a.engine.sync()                      // pulls the edit, keeps the tombstone, pushes the delete
        _ = try await b.engine.sync()
        XCTAssertEqual(try a.db.finishedEntries(from: t0, to: t0.addingTimeInterval(86400)), [])
        XCTAssertEqual(try b.db.finishedEntries(from: t0, to: t0.addingTimeInterval(86400)), [])
    }

    // R5 / Review Focus 3: a failed push keeps the outbox; the next cycle delivers.
    func testOutboxSurvivesFailedPush() async throws {
        _ = try seedA()
        await server.setFailNext(true)
        do { _ = try await a.engine.sync(); XCTFail("expected failure") } catch {}
        XCTAssertEqual(try a.db.pendingOutbox().count, 6)   // client, project, repo x2 (add, assign), entry x2 (start, stop)
        let s = try await a.engine.sync()
        XCTAssertEqual(s.pushed, 4)
        XCTAssertEqual(try a.db.pendingOutbox(), [])
    }

    // R6: pull before push.
    func testPullHappensBeforePush() async throws {
        let spy = SpyTransport(server)
        let db = try AppDatabase.inMemory()
        var c = Client(name: "x"); try db.insert(&c)
        _ = try await SyncEngine(database: db, transport: spy).sync()
        let calls = await spy.calls
        XCTAssertEqual(calls, ["fetch", "save"])
    }

    // R9: replaying a batch changes nothing and logs nothing.
    func testReplayIsIdempotent() async throws {
        _ = try seedA()
        _ = try await a.engine.sync()
        let changes = try await server.fetchChanges(since: nil)
        _ = try await b.engine.apply(changes)
        let before = try b.db.read { try Row.fetchAll($0, sql: "SELECT uuid, modifiedAt, name FROM project") }
        let again = try await b.engine.apply(changes)
        XCTAssertEqual(again.pulled, 0)
        XCTAssertEqual(try b.db.read { try Row.fetchAll($0, sql: "SELECT uuid, modifiedAt, name FROM project") }, before)
        XCTAssertEqual(try b.db.pendingOutbox(), [])
    }

    // R8: a child whose parent was deleted before B ever synced gets a null reference.
    func testMissingParentGetsNullReference() async throws {
        let (c, _, _, _) = try seedA()
        _ = try await a.engine.sync()
        try a.db.delete(c)
        _ = try await a.engine.sync()
        _ = try await b.engine.sync()
        XCTAssertEqual(try b.db.allClients(), [])
        XCTAssertNil(try b.db.allProjects()[0].clientId)
    }

    // Settings sync per key by LWW; local keys never travel.
    func testSettingsSync() async throws {
        try a.db.setSetting("userName", "Martin")
        try a.db.setSetting("databasePath", "/local")
        _ = try await a.engine.sync(); _ = try await b.engine.sync()
        XCTAssertEqual(try b.db.setting("userName"), "Martin")
        XCTAssertNil(try b.db.setting("databasePath"))
        try await Task.sleep(nanoseconds: 5_000_000)   // GRDB stores dates at ms precision; two real-clock writes must not tie
        try b.db.setSetting("userName", "M. Hans")
        _ = try await b.engine.sync(); _ = try await a.engine.sync()
        XCTAssertEqual(try a.db.setting("userName"), "M. Hans")
    }

    // The token advances only with a committed apply and is per device.
    func testTokenIsStoredPerDevice() async throws {
        _ = try seedA()
        _ = try await a.engine.sync()
        XCTAssertNotNil(try a.db.setting(SyncEngine.tokenKey))
        XCTAssertNil(try b.db.setting(SyncEngine.tokenKey))
        _ = try await b.engine.sync()
        let s = try await b.engine.sync()
        XCTAssertEqual(s.pulled, 0)
    }

    // R16: both uuid orders, so the guard path and the re-point path each run every time.
    private func collapseRepos(aUUID: String, bUUID: String, deleteOnA: Bool = false) async throws {
        var ra = Repo(owner: "acme", name: "web", uuid: aUUID), rb = Repo(owner: "acme", name: "web", uuid: bUUID)
        try a.db.insert(&ra); try b.db.insert(&rb)
        if deleteOnA { try a.db.delete(ra) }
        for d in (deleteOnA ? [b!, a!, b!, a!] : [a!, b!, a!, b!, a!]) { _ = try await d.engine.sync() }
        let surviving = min(aUUID, bUUID)
        if deleteOnA {
            XCTAssertEqual(try a.db.allRepos(), []); XCTAssertEqual(try b.db.allRepos(), [])
        } else {
            let va = try a.db.allRepos(), vb = try b.db.allRepos()
            XCTAssertEqual(va.map(\.uuid), [surviving]); XCTAssertEqual(vb.map(\.uuid), [surviving])
        }
        let repos = await server.records().keys.filter { $0.type == "Repo" }.map(\.name)
        XCTAssertEqual(repos, deleteOnA ? [] : [surviving])
        XCTAssertEqual(try a.db.pendingOutbox(), []); XCTAssertEqual(try b.db.pendingOutbox(), [])
    }
    func testSameRepoCollapsesAHasSmallerUUID() async throws { try await collapseRepos(aUUID: "A-1", bUUID: "B-1") }
    func testSameRepoCollapsesBHasSmallerUUID() async throws { try await collapseRepos(aUUID: "B-1", bUUID: "A-1") }
    func testSameRepoCollapsesWithDeletedCopyOnA() async throws { try await collapseRepos(aUUID: "A-1", bUUID: "B-1", deleteOnA: true) }
    func testSameRepoCollapsesWithDeletedCopyOnAReversed() async throws { try await collapseRepos(aUUID: "B-1", bUUID: "A-1", deleteOnA: true) }

    private func collapseEntries(aUUID: String, bUUID: String, deleteOnA: Bool = false) async throws {
        var ea = Entry(description: "x", startUTC: t0, endUTC: t0.addingTimeInterval(60), importedKey: "k", uuid: aUUID)
        var eb = Entry(description: "x", startUTC: t0, endUTC: t0.addingTimeInterval(60), importedKey: "k", uuid: bUUID)
        try a.db.insert(&ea); try b.db.insert(&eb)
        if deleteOnA { try a.db.delete(ea) }
        for d in (deleteOnA ? [b!, a!, b!, a!] : [a!, b!, a!, b!, a!]) { _ = try await d.engine.sync() }
        let range = (t0.addingTimeInterval(-10), t0.addingTimeInterval(86400))
        let va = try a.db.finishedEntries(from: range.0, to: range.1), vb = try b.db.finishedEntries(from: range.0, to: range.1)
        let entries = await server.records().keys.filter { $0.type == "Entry" }.map(\.name)
        if deleteOnA {
            XCTAssertEqual(va, []); XCTAssertEqual(vb, []); XCTAssertEqual(entries, [])
        } else {
            XCTAssertEqual(va.map(\.uuid), [min(aUUID, bUUID)]); XCTAssertEqual(vb.map(\.uuid), [min(aUUID, bUUID)])
            XCTAssertEqual(entries, [min(aUUID, bUUID)])
        }
        XCTAssertEqual(try a.db.pendingOutbox(), []); XCTAssertEqual(try b.db.pendingOutbox(), [])
    }
    func testSameImportedKeyCollapsesAHasSmallerUUID() async throws { try await collapseEntries(aUUID: "A-1", bUUID: "B-1") }
    func testSameImportedKeyCollapsesBHasSmallerUUID() async throws { try await collapseEntries(aUUID: "B-1", bUUID: "A-1") }
    func testSameImportedKeyCollapsesWithDeletedCopyOnA() async throws { try await collapseEntries(aUUID: "A-1", bUUID: "B-1", deleteOnA: true) }
    func testSameImportedKeyCollapsesWithDeletedCopyOnAReversed() async throws { try await collapseEntries(aUUID: "B-1", bUUID: "A-1", deleteOnA: true) }

    // R16: a child pushed under the losing repo uuid is re-sent with the surviving one.
    func testChildrenAreRequeuedAfterRepoRepoint() async throws {
        var rb = Repo(owner: "acme", name: "web", uuid: "B-1"); try b.db.insert(&rb)
        var eb = Entry(description: "x", startUTC: t0, endUTC: t0.addingTimeInterval(60), repoId: rb.id); try b.db.insert(&eb)
        _ = try await b.engine.sync()
        var ra = Repo(owner: "acme", name: "web", uuid: "A-1"); try a.db.insert(&ra)
        _ = try await a.engine.sync()
        for d in [b!, a!, b!] { _ = try await d.engine.sync() }
        let range = (t0.addingTimeInterval(-10), t0.addingTimeInterval(86400))
        let onA = try a.db.finishedEntries(from: range.0, to: range.1)
        XCTAssertEqual(onA.count, 1)
        XCTAssertEqual(onA[0].repoId, try a.db.allRepos()[0].id)
        let rec = await server.records().values.first { $0.type == "Entry" }
        XCTAssertEqual(rec?.string("repoUUID"), "A-1")
        XCTAssertEqual(try a.db.pendingOutbox(), []); XCTAssertEqual(try b.db.pendingOutbox(), [])
    }

    // The server refuses to resurrect a deleted record.
    func testServerReportsNotFoundForDeletedRecord() async throws {
        let rec = SyncRecord(type: "Client", name: "u1", fields: [:])
        _ = try await server.save([rec])
        try await server.delete([rec.id])
        let out = try await server.save([rec])
        XCTAssertEqual(out[rec.id], .notFound)
        let names = await server.records().keys
        XCTAssertTrue(names.isEmpty)
    }

    // R4 race: B's edit is pushed after A's deletion reached the server; notFound deletes B's row.
    func testPushOfDeletedEntryDeletesLocalRow() async throws {
        let (_, _, _, e) = try seedA()
        _ = try await a.engine.sync(); _ = try await b.engine.sync()
        var eb = try b.db.finishedEntries(from: t0, to: t0.addingTimeInterval(86400))[0]
        try edit(b.db, &eb, at: Date().addingTimeInterval(3600)) { $0.description = "late edit" }
        let ad = a!
        let racing = HookTransport(server) { _ in
            try ad.db.delete(e)
            _ = try await ad.engine.sync()                  // the deletion lands between B's fetch and B's save
        }
        _ = try await SyncEngine(database: b.db, transport: racing).sync()
        _ = try await b.engine.sync()
        XCTAssertEqual(try b.db.finishedEntries(from: t0, to: t0.addingTimeInterval(86400)), [])
        XCTAssertEqual(try a.db.finishedEntries(from: t0, to: t0.addingTimeInterval(86400)), [])
        XCTAssertEqual(try b.db.pendingOutbox(), [])
        let names = await server.records().keys.map(\.name)
        XCTAssertFalse(names.contains(e.uuid))
    }

    // notFound for a setting must not delete it; it stays queued.
    func testNotFoundForSettingKeepsLocalValue() async throws {
        try a.db.setSetting("userName", "Martin")
        let engine = SyncEngine(database: a.db, transport: HookTransport(server, outcomeOverride: .notFound))
        _ = try await engine.sync()
        XCTAssertEqual(try a.db.setting("userName"), "Martin")
        XCTAssertEqual(try a.db.pendingOutbox().count, 1)
    }

    // A local winner whose version was overwritten on the server is pushed again.
    func testLocalWinnerIsPushedAgain() async throws {
        var (_, p, _, _) = try seedA()
        _ = try await a.engine.sync(); _ = try await b.engine.sync()
        var pb = try b.db.allProjects()[0]
        let base = Date().addingTimeInterval(3600)
        try edit(b.db, &pb, at: base.addingTimeInterval(20)) { $0.name = "B newer" }
        try edit(a.db, &p, at: base.addingTimeInterval(10)) { $0.name = "A older" }
        let bd = b!
        let interleaved = HookTransport(server) { _ in _ = try await bd.engine.sync() }   // B pushes during A's cycle
        _ = try await SyncEngine(database: a.db, transport: interleaved).sync()           // A's blind save overwrites B's
        _ = try await b.engine.sync()                                                     // B pulls the older one, wins, re-queues
        _ = try await a.engine.sync()
        XCTAssertEqual(try a.db.allProjects()[0].name, "B newer")
        XCTAssertEqual(try b.db.allProjects()[0].name, "B newer")
    }

    // Outbox items added while a push is in flight survive the post-push cleanup.
    func testOutboxItemsAddedDuringPushSurvive() async throws {
        _ = try seedA()
        _ = try await a.engine.sync()
        var p = try a.db.allProjects()[0]
        try edit(a.db, &p, at: Date().addingTimeInterval(3600)) { $0.name = "first" }
        let ad = a!
        let editing = HookTransport(server) { _ in
            var q = try ad.db.allProjects()[0]
            try edit(ad.db, &q, at: Date().addingTimeInterval(7200)) { $0.name = "second" }
        }
        _ = try await SyncEngine(database: a.db, transport: editing).sync()
        XCTAssertEqual(try a.db.pendingOutbox().count, 1)
        _ = try await a.engine.sync()
        XCTAssertEqual(try a.db.pendingOutbox(), [])
        let rec = await server.records().values.first { $0.type == "Project" }
        XCTAssertEqual(rec?.string("name"), "second")
    }

    // Remote settings outside the synced set are ignored.
    func testUnsyncedRemoteSettingIsIgnored() throws {
        let rec = RecordMapper.record(settingKey: "databasePath", value: "/x", modifiedAt: t0, modifiedBy: "z")
        _ = try b.db.write { try SyncEngine.applyRecord(rec, in: $0) }
        XCTAssertNil(try b.db.setting("databasePath"))
    }

    // A second sync() during a running cycle shares its result.
    func testSyncIsSingleFlight() async throws {
        _ = try seedA()
        let spy = SpyTransport(server)
        let engine = SyncEngine(database: a.db, transport: spy)
        async let s1 = engine.sync(), s2 = engine.sync()
        let (r1, r2) = try await (s1, s2)
        XCTAssertEqual(r1, r2)
        let calls = await spy.calls
        XCTAssertEqual(calls, ["fetch", "save"])
    }
}
