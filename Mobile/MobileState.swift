import Foundation
import Observation
import TimeCore

@Observable @MainActor
final class MobileState {
    static weak var shared: MobileState?   // read only from @MainActor tasks
    let db: AppDatabase
    var running: Entry?
    var recents: [RecentItem] = []
    var projects: [Project] = []
    var repos: [Repo] = []
    var issueRows: [IssueRow] = []
    var allIssueRows: [IssueRow] = []
    var monthTotal: Double = 0
    private var finishedMonthHours: Double = 0
    var now = Date()
    var lastError: String?
    var githubError: String?
    var syncStatus = "Sync: not started"
    private let transport: CloudKitTransport
    private let engine: SyncEngine
    private var debounced: Task<Void, Never>?

    static var databaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Stint/stint.sqlite")
    }

    init() {
        db = try! AppDatabase.open(at: Self.databaseURL)      // the phone has no alert path; a failure here is a programming error
        transport = CloudKitTransport(database: db)
        engine = SyncEngine(database: db, transport: transport)
        Self.shared = self
        refresh()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: CloudKitTransport.accountChangedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.syncNow(reason: "account changed") }
        }
    }

    func refresh() {
        do {
            running = try db.runningEntry()
            recents = try db.recents(limit: 10)
            projects = try db.allProjects()
            repos = try db.allRepos()
            issueRows = try db.openIssueRows()
            allIssueRows = try db.searchIssueRows(closedSince: Date().addingTimeInterval(-30 * 86400))
            let n = Date()
            let total = try db.monthTotalHours(now: n, calendar: .current)
            finishedMonthHours = total - (running.map { max(0, n.timeIntervalSince($0.startUTC)) / 3600 } ?? 0)
            now = n
            monthTotal = total
        } catch { lastError = "\(error)" }
    }

    private func tick() {
        now = Date()
        monthTotal = finishedMonthHours + (running.map { max(0, now.timeIntervalSince($0.startUTC)) / 3600 } ?? 0)
    }

    var userName: String {
        get { (try? db.setting("userName")) ?? "" }
        set { try? db.setSetting("userName", newValue); scheduleSync() }
    }

    func projectName(_ id: Int64?) -> String { projects.first { $0.id == id }?.name ?? "" }

    func elapsed(_ e: Entry) -> String {
        let s = Int(max(0, now.timeIntervalSince(e.startUTC)))
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    func perform(_ block: () throws -> Void) {
        do { try block(); lastError = nil } catch { lastError = "\(error)" }
        refresh()
        scheduleSync()
    }

    func start(_ item: RecentItem) {
        perform { try db.start(description: item.description, projectId: item.projectId, repoId: item.repoId,
                               issueNumber: item.issueNumber, issueTitle: item.issueTitle) }
        Task { await syncNow(reason: "start") }
    }
    func startIssue(_ row: IssueRow) {
        perform { try db.start(description: "#\(row.issue.number): \(row.issue.title)", projectId: row.repo.projectId,
                               repoId: row.repo.id, issueNumber: row.issue.number, issueTitle: row.issue.title) }
        Task { await syncNow(reason: "start") }
    }
    func startNew(description: String, projectId: Int64?) {
        perform { try db.start(description: description, projectId: projectId) }
        Task { await syncNow(reason: "start") }
    }
    func stop() {
        perform { try db.stopRunning() }
        Task { await syncNow(reason: "stop") }     // a stop must leave the phone before it is locked
    }
    func update(_ entry: Entry) -> Bool {
        if let end = entry.endUTC, end <= entry.startUTC { lastError = "End must be after start."; return false }
        perform { try db.update(entry) }
        return lastError == nil
    }
    func delete(_ entry: Entry) {
        perform { try db.delete(entry) }
        Task { await syncNow(reason: "delete") }
    }
    func assignRepo(_ repoId: Int64, to projectId: Int64?) { perform { try db.assignRepo(repoId, toProject: projectId) } }
    func createProject(named name: String) -> Int64? { var p = Project(clientId: nil, name: name); perform { try db.insert(&p) }; return p.id }
    func windowEntries() -> [Entry] {
        (try? db.entries(from: windowStart(now: Date(), calendar: .current), to: Date().addingTimeInterval(86400))) ?? []
    }

    // MARK: sync

    func scheduleSync() {
        debounced?.cancel()
        debounced = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.syncNow(reason: "local change")
        }
    }

    func syncNow(reason: String) async {
        let available = await transport.accountAvailable()
        guard !Task.isCancelled else { return }   // a superseded debounce must not report "not signed in"
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
            try db.pruneEntries(startingBefore: windowStart(now: Date(), calendar: .current))   // R14
            refresh()
            let stamp = Date().formatted(date: .omitted, time: .shortened)
            syncStatus = "Synced \(stamp): \(s.pushed) up, \(s.pulled) down" + (s.deleted > 0 ? ", \(s.deleted) deleted" : "")
                + (s.failed > 0 ? ", \(s.failed) failed" : "")
        } catch {
            syncStatus = "Sync problem: \(error.localizedDescription)"
        }
    }

    func syncIssues() async {
        let accounts = KeychainStore.githubAccounts().map { GitHubAccountCredential(label: $0.label, token: $0.token) }
        guard !accounts.isEmpty else { githubError = "No GitHub token. Add one in Settings."; return }
        let outcome = await AccountSync.run(accounts: accounts, db: db, closedSince: Date().addingTimeInterval(-30 * 86400))
        if outcome.applied {
            refresh()
            await syncNow(reason: "issues")   // the snapshot (R18) leaves at once; nothing to push when unchanged
        }
        githubError = outcome.rejectedLabels.isEmpty ? nil : "GitHub rejected the token for \(outcome.rejectedLabels.joined(separator: ", "))."
    }
}
