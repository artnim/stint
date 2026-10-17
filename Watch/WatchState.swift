import Foundation
import Observation
import TimeCore
import WidgetKit

@Observable @MainActor
final class WatchState {
    /// One instance on every launch path, including a background relaunch for a refresh task.
    /// Previews (and Xcode's preview launch) get sample data and no sync.
    static let shared = isRunningForPreviews ? WatchState(db: .preview(), syncing: false)
        : WatchState(db: try! AppDatabase.open(at: databaseURL), syncing: true)   // no alert path on the wrist; a failure here is a programming error
    let db: AppDatabase
    var running: Entry?
    var lastFinished: Entry?
    var recents: [RecentItem] = []
    var projects: [Project] = []
    var issueRows: [IssueRow] = []
    var today: [Entry] = []
    var lastError: String?
    var syncStatus = "Sync: not started"
    private(set) var complicationReloadedAt: Date?
    private let transport: CloudKitTransport?   // nil in previews: no iCloud
    private let engine: SyncEngine?
    private var writing = false   // a tap while a write is pending is ignored

    static var databaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Stint/stint.sqlite")
    }

    init(db: AppDatabase, syncing: Bool) {
        self.db = db
        transport = syncing ? CloudKitTransport(database: db) : nil
        engine = transport.map { SyncEngine(database: db, transport: $0) }
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
        let snapshot = ComplicationStore.Snapshot(description: running?.description, start: running?.startUTC, uuid: running?.uuid)
        ComplicationStore.changeToken = try? db.setting(SyncEngine.tokenKey)   // the widget checks CloudKit from here
        if snapshot != ComplicationStore.load() {
            ComplicationStore.save(snapshot)
            WidgetCenter.shared.reloadAllTimelines()
            complicationReloadedAt = Date()
        }
    }

    func projectName(_ id: Int64?) -> String { projects.first { $0.id == id }?.name ?? "" }

    /// Pulls first (bounded, see `pullFirst`) so the write acts on fresh state: a Stop after the Mac already
    /// stopped does nothing, a Start stops the entry that is actually running. Taps are serialized by ignoring
    /// a second one while a write is pending.
    private func perform(_ reason: String, _ block: () throws -> Void) async {
        guard !writing else { return }
        writing = true
        defer { writing = false }
        await pullFirst()
        do { try block(); lastError = nil } catch { lastError = "\(error)" }
        refresh()
        Task { await syncNow(reason: reason) }        // R19: a tap leaves the wrist at once
    }

    /// Returns when a sync finishes or after `timeout`, whichever comes first; offline or without iCloud the sync
    /// returns at once and the write goes ahead as before (R10: never block the user). A sync still running at
    /// the timeout completes in the background, and the engine is single-flight, so the post-write sync joins it.
    /// Not a task group: a group waits for every child, and the CloudKit calls need not honour cancellation.
    private func pullFirst(timeout: Duration = .seconds(3)) async {
        let gate = Gate()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            gate.continuation = c
            Task { @MainActor in await self.syncNow(reason: "before write"); gate.open() }
            Task { @MainActor in try? await Task.sleep(for: timeout); gate.open() }
        }
    }

    func start(_ item: RecentItem) async {
        await perform("start") { try db.start(description: item.description, projectId: item.projectId, repoId: item.repoId,
                                              issueNumber: item.issueNumber, issueTitle: item.issueTitle) }
    }
    func startIssue(_ row: IssueRow) async {
        await perform("start") { try db.start(description: "#\(row.issue.number): \(row.issue.title)", projectId: row.repo.projectId,
                                              repoId: row.repo.id, issueNumber: row.issue.number, issueTitle: row.issue.title) }
    }
    func restartLast() async {
        guard let e = lastFinished else { return }
        await perform("restart") { try db.start(description: e.description, projectId: e.projectId, repoId: e.repoId,
                                                issueNumber: e.issueNumber, issueTitle: e.issueTitle, tags: e.tags) }
    }
    func stop() async { await perform("stop") { try db.stopRunning() } }
    func delete(_ entry: Entry) async { await perform("delete") { try db.delete(entry) } }

    // MARK: sync

    func syncNow(reason: String) async {
        guard let transport, let engine else { return }
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
            refresh()   // the pull may have applied before the push failed
        }
    }
}

/// Resumes its continuation once, whichever caller opens it first.
@MainActor private final class Gate {
    var continuation: CheckedContinuation<Void, Never>?
    func open() { continuation?.resume(); continuation = nil }
}
