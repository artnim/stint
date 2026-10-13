import XCTest
@testable import TimeCore

final class ReportModelTests: XCTestCase {
    private func e(_ s: String, _ end: String, _ d: String = "work", project: String = "P",
                   client: String = "C", tags: [String] = []) -> ReportEntry {
        ReportEntry(description: d, project: project, client: client, user: "Martin",
                    start: local(s), end: local(end), tags: tags)
    }

    private var defaults: ReportOptions { ReportOptions() }

    func testEmptyInputGivesNil() {
        XCTAssertNil(buildReport([], options: defaults, calendar: berlin))
    }

    func testGroupsByDayWithSubtotalsAndTotal() throws {
        let r = try XCTUnwrap(buildReport([
            e("2026-08-04 09:00", "2026-08-04 10:30"),
            e("2026-08-03 09:00", "2026-08-03 10:00"),
            e("2026-08-03 11:00", "2026-08-03 11:45"),
        ], options: defaults, calendar: berlin))
        XCTAssertEqual(r.days.map(\.day), [Day(year: 2026, month: 8, day: 3), Day(year: 2026, month: 8, day: 4)])
        XCTAssertEqual(r.days[0].label, "Montag, 03.08.2026")
        XCTAssertEqual(r.days[0].totalHours, 1.75, accuracy: 1e-9)
        XCTAssertEqual(r.days[0].entries.map { hhmm($0.start) }, ["09:00", "11:00"])
        XCTAssertEqual(r.totalHours, 3.25, accuracy: 1e-9)
        XCTAssertEqual(r.entryCount, 3)
        XCTAssertEqual(r.title, "Leistungsnachweis")
        XCTAssertEqual(r.meta, ReportMeta(client: "C", project: "P", user: "Martin", period: "03.08.2026 – 04.08.2026"))
        XCTAssertEqual(r.warnings, [])
    }

    func testNewestFirst() throws {
        var o = defaults
        o.newestFirst = true
        let r = try XCTUnwrap(buildReport([
            e("2026-08-03 09:00", "2026-08-03 10:00"),
            e("2026-08-03 11:00", "2026-08-03 11:45"),
            e("2026-08-04 09:00", "2026-08-04 10:30"),
        ], options: o, calendar: berlin))
        XCTAssertEqual(r.days.map(\.day.day), [4, 3])
        XCTAssertEqual(r.days[1].entries.map { hhmm($0.start) }, ["11:00", "09:00"])
    }

    func testAutoColumns() throws {
        let plain = try XCTUnwrap(buildReport([e("2026-08-03 09:00", "2026-08-03 10:00")], options: defaults, calendar: berlin))
        XCTAssertEqual(plain.columns, [.time, .description, .duration])

        let withIssues = try XCTUnwrap(buildReport([
            e("2026-08-03 09:00", "2026-08-03 10:00", "#1: a", tags: ["t"]),
            e("2026-08-03 10:00", "2026-08-03 11:00", "#2: b"),
            e("2026-08-03 11:00", "2026-08-03 12:00", "#3: c"),
        ], options: defaults, calendar: berlin))
        XCTAssertEqual(withIssues.columns, [.time, .issue, .description, .tags, .duration])

        var o = defaults
        o.showTimes = false; o.showIssue = false; o.showTags = true
        let forced = try XCTUnwrap(buildReport([e("2026-08-03 09:00", "2026-08-03 10:00", "#1: a")], options: o, calendar: berlin))
        XCTAssertEqual(forced.columns, [.description, .tags, .duration])
    }

    func testIssueColumnNeedsAtLeastThreeOrAQuarter() throws {
        let two = (0..<2).map { e("2026-08-03 0\($0 + 1):00", "2026-08-03 0\($0 + 2):00", "#\($0): x") }
        XCTAssertFalse(try XCTUnwrap(buildReport(two, options: defaults, calendar: berlin)).columns.contains(.issue))
    }

    func testDurationRoundingUpAndSyntheticCollisionNudge() throws {
        var o = defaults
        o.durationRounding = .up
        // raw 09:00-09:50 -> 1.00 h shown 09:00-10:00; raw 09:52-10:05 -> 0.25 h, nearest snap 09:45 < 10:00 -> nudged to 10:00
        let r = try XCTUnwrap(buildReport([
            e("2026-08-03 09:00", "2026-08-03 09:50"),
            e("2026-08-03 09:52", "2026-08-03 10:05"),
        ], options: o, calendar: berlin))
        let d = r.days[0].entries
        XCTAssertEqual(d[0].hours, 1.0, accuracy: 1e-9)
        XCTAssertEqual(hhmm(d[0].end), "10:00")
        XCTAssertEqual(d[1].hours, 0.25, accuracy: 1e-9)
        XCTAssertEqual(hhmm(d[1].start), "10:00")
        XCTAssertEqual(r.totalHours, 1.25, accuracy: 1e-9)
        XCTAssertEqual(r.warnings, []) // raw data is on grid after rounding, no real overlap
    }

    func testRealOverlapStaysAndIsWarnedWithoutDurationRounding() throws {
        let r = try XCTUnwrap(buildReport([
            e("2026-08-03 09:00", "2026-08-03 10:00"),
            e("2026-08-03 09:30", "2026-08-03 10:30"),
        ], options: defaults, calendar: berlin))
        XCTAssertEqual(hhmm(r.days[0].entries[1].start), "09:30")
        XCTAssertEqual(r.warnings, ["2026-08-03  overlap: 09:00-10:00 and 09:30-10:30"])
    }

    func testEntryCrossingMidnightStaysOnItsStartDay() throws {
        let r = try XCTUnwrap(buildReport([e("2026-08-03 23:30", "2026-08-04 00:30")], options: defaults, calendar: berlin))
        XCTAssertEqual(r.days.count, 1)
        XCTAssertEqual(r.days[0].day.day, 3)
        XCTAssertEqual(r.days[0].totalHours, 1.0, accuracy: 1e-9)
    }

    func testDSTChangeDayCountsRealHours() throws {
        // 2026-10-25 00:00 UTC = 02:00 CEST; 01:30 UTC = 02:30 CET. 1.5 real hours, wall clock looks like 30 min.
        let start = Date(timeIntervalSince1970: 1_792_886_400)       // 2026-10-25T00:00:00Z
        let entry = ReportEntry(description: "night", start: start, end: start.addingTimeInterval(5400))
        let r = try XCTUnwrap(buildReport([entry], options: defaults, calendar: berlin))
        XCTAssertEqual(r.totalHours, 1.5, accuracy: 1e-9)
        XCTAssertEqual(r.days[0].day, Day(year: 2026, month: 10, day: 25))
    }

    func testMetaWithSeveralClientsAndProjects() throws {
        let r = try XCTUnwrap(buildReport([
            e("2026-08-03 09:00", "2026-08-03 10:00", project: "A", client: "X"),
            e("2026-08-03 10:00", "2026-08-03 11:00", project: "B", client: "Y"),
        ], options: defaults, calendar: berlin))
        XCTAssertEqual(r.meta.client, "mehrere (2)")
        XCTAssertEqual(r.meta.project, "mehrere (2)")
    }

    func testTagSummary() throws {
        var o = defaults
        o.summary = true
        let r = try XCTUnwrap(buildReport([
            e("2026-08-03 09:00", "2026-08-03 10:00", tags: ["a", "b"]),
            e("2026-08-03 10:00", "2026-08-03 10:45"),
        ], options: o, calendar: berlin))
        XCTAssertEqual(r.tagSummary, [TagShare(name: "ohne Tag", hours: 0.75),
                                      TagShare(name: "a", hours: 0.5),
                                      TagShare(name: "b", hours: 0.5)])
        XCTAssertEqual(try XCTUnwrap(buildReport([e("2026-08-03 09:00", "2026-08-03 10:00")], options: defaults, calendar: berlin)).tagSummary, [])
    }

    func testTitleOverrideAndEnglish() throws {
        var o = defaults
        o.language = .en
        o.title = "Timesheet August 2026"
        let r = try XCTUnwrap(buildReport([e("2026-08-03 09:00", "2026-08-03 10:00")], options: o, calendar: berlin))
        XCTAssertEqual(r.title, "Timesheet August 2026")
        XCTAssertEqual(r.days[0].label, "Monday, 03 Aug 2026")
        XCTAssertEqual(r.strings.total, "Total")
    }

    func testMonthRange() {
        let (s, e) = monthRange(year: 2026, month: 12, calendar: berlin)
        XCTAssertEqual(s, local("2026-12-01 00:00:00"))
        XCTAssertEqual(e, local("2027-01-01 00:00:00"))
    }

    func testReportEntriesFromDatabaseResolveNamesAndFilters() throws {
        let db = try AppDatabase.inMemory()
        var acme = Client(name: "ACME"); var globex = Client(name: "Globex")
        try db.write { try acme.insert($0); try globex.insert($0) }
        var web = Project(clientId: acme.id, name: "Website"); var app = Project(clientId: globex.id, name: "App")
        try db.write { try web.insert($0); try app.insert($0) }
        let t0 = local("2026-08-03 09:00")
        try db.start(description: "#1: a", projectId: web.id, tags: ["x"], at: t0)
        try db.stopRunning(at: t0.addingTimeInterval(3600))
        try db.start(description: "b", projectId: app.id, at: t0.addingTimeInterval(7200))
        try db.stopRunning(at: t0.addingTimeInterval(9000))
        try db.start(description: "running", projectId: app.id, at: t0.addingTimeInterval(10000))

        let all = try db.reportEntries(from: t0, to: t0.addingTimeInterval(86400), userName: "Martin")
        XCTAssertEqual(all.map(\.description), ["a", "b"])
        XCTAssertEqual(all[0].issue, "#1")
        XCTAssertEqual(all[0].project, "Website")
        XCTAssertEqual(all[0].client, "ACME")
        XCTAssertEqual(all[0].user, "Martin")
        XCTAssertEqual(all[0].tags, ["x"])

        let onlyGlobex = try db.reportEntries(from: t0, to: t0.addingTimeInterval(86400),
                                              filter: ReportFilter(clientId: globex.id), userName: "Martin")
        XCTAssertEqual(onlyGlobex.map(\.description), ["b"])
        let onlyWeb = try db.reportEntries(from: t0, to: t0.addingTimeInterval(86400),
                                           filter: ReportFilter(projectId: web.id), userName: "Martin")
        XCTAssertEqual(onlyWeb.map(\.description), ["a"])
    }
}
