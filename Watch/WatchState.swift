import Foundation
import Observation
import TimeCore
import WidgetKit

@Observable @MainActor
final class WatchState {
    static weak var shared: WatchState?   // read only from @MainActor tasks
    let db: AppDatabase
    var running: Entry?
    var lastFinished: Entry?
    var recents: [RecentItem] = []
    var projects: [Project] = []
    var issueRows: [IssueRow] = []
    var today: [Entry] = []
    var lastError: String?
    var syncStatus = "Sync: not started"
    private let transport: CloudKitTransport
    private let engine: SyncEngine

    static var databaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Stint/stint.sqlite")
    }

    init() {
        db = try! AppDatabase.open(at: Self.databaseURL)      // no alert path on the wrist; a failure here is a programming error
        transport = CloudKitTransport(database: db)
        engine = SyncEngine(database: db, transport: transport)
        Self.shared = self
        refresh()
        NotificationCenter.default.addObserver(forName: CloudKitTransport.accountChangedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.syncNow(reason: "account changed") }
        }
    }

    func refresh() {
        do {
            running = try db.runningEntry()
            recents = try db.recents(limit: 10)
            projects = try db.allProjects()
            issueRows = try db.openIssueRows()
            let cal = Calendar.current
            let dayStart = cal.startOfDay(for: Date())
            today = try db.entries(from: dayStart, to: cal.date(byAdding: .day, value: 1, to: dayStart)!).reversed()
            lastFinished = try db.finishedEntries(from: windowStart(now: Date(), months: 1, calendar: cal), to: Date().addingTimeInterval(86400)).last
        } catch { lastError = "\(error)" }
        let snapshot = ComplicationStore.Snapshot(description: running?.description, start: running?.startUTC)
        if snapshot != ComplicationStore.load() {
            ComplicationStore.save(snapshot)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func projectName(_ id: Int64?) -> String { projects.first { $0.id == id }?.name ?? "" }

    private func perform(_ reason: String, _ block: () throws -> Void) {
        do { try block(); lastError = nil } catch { lastError = "\(error)" }
        refresh()
        Task { await syncNow(reason: reason) }        // R19: a tap leaves the wrist at once
    }

    func start(_ item: RecentItem) {
        perform("start") { try db.start(description: item.description, projectId: item.projectId, repoId: item.repoId,
                                        issueNumber: item.issueNumber, issueTitle: item.issueTitle) }
    }
    func startIssue(_ row: IssueRow) {
        perform("start") { try db.start(description: "#\(row.issue.number): \(row.issue.title)", projectId: row.repo.projectId,
                                        repoId: row.repo.id, issueNumber: row.issue.number, issueTitle: row.issue.title) }
    }
    func restartLast() {
        guard let e = lastFinished else { return }
        perform("restart") { try db.start(description: e.description, projectId: e.projectId, repoId: e.repoId,
                                          issueNumber: e.issueNumber, issueTitle: e.issueTitle, tags: e.tags) }
    }
    func stop() { perform("stop") { try db.stopRunning() } }
    func delete(_ entry: Entry) { perform("delete") { try db.delete(entry) } }

    // MARK: sync

    func syncNow(reason: String) async {
        let available = await transport.accountAvailable()
        guard !Task.isCancelled else { return }
        guard available else { syncStatus = "Sync off: not signed in to iCloud"; return }
        do {
            // R11: a different iCloud account keeps the local data and stops syncing
            let user = try await transport.userRecordName()
            if let stored = try db.setting("syncUserRecordID"), !stored.isEmpty {
                guard stored == user else { syncStatus = "iCloud account changed, sync stopped"; return }
            } else {
                try db.setSetting("syncUserRecordID", user)
            }
            try await transport.prepare()
            let s = try await engine.sync()
            try db.pruneEntries(startingBefore: windowStart(now: Date(), months: 1, calendar: .current))   // R17
            try db.applyAssignedIssueSnapshot()                                                          // R18, after every cycle (Review Focus 2)
            refresh()
            let stamp = Date().formatted(date: .omitted, time: .shortened)
            syncStatus = "Synced \(stamp): \(s.pushed) up, \(s.pulled) down" + (s.deleted > 0 ? ", \(s.deleted) deleted" : "") + (s.failed > 0 ? ", \(s.failed) failed" : "")
        } catch {
            syncStatus = "Sync problem: \(error.localizedDescription)"
        }
    }
}
