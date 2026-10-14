import AppKit
import Foundation
import Observation
import TimeCore

@Observable @MainActor
final class AppState {
    private(set) var db: AppDatabase
    var running: Entry?
    /// Bumped on every refresh(); lets views regenerate derived data (e.g. the report PDF).
    var dataVersion = 0
    var recents: [RecentItem] = []
    var projects: [Project] = []
    var clients: [Client] = []
    var repos: [Repo] = []
    var now = Date()
    var staleRunning: Entry?
    var lastError: String?
    var issueRows: [IssueRow] = []          // assigned to me (popover default)
    var allIssueRows: [IssueRow] = []       // every open issue of tracked repos + recently closed (popover search)

    /// Closed issues stay searchable for this long, so time can be booked on something just closed.
    static var closedSearchCutoff: Date { Date().addingTimeInterval(-30 * 86400) }
    var githubError: String?

    private var ticker: Timer?

    static weak var shared: AppState?   // read only from @MainActor tasks

    var syncStatus = "Sync: not started"
    private var transport: CloudKitTransport?
    private var engine: SyncEngine?
    private var debouncedSync: Task<Void, Never>?
    private var periodicSync: Timer?

    func startSync() {
        Self.shared = self
        let transport = CloudKitTransport(database: db)
        self.transport = transport
        engine = SyncEngine(database: db, transport: transport)
        periodicSync = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncNow(reason: "periodic") }
        }
        NotificationCenter.default.addObserver(forName: CloudKitTransport.accountChangedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.syncNow(reason: "account changed") }
        }
        Task { await syncNow(reason: "launch") }
    }

    func syncNow(reason: String) async {
        guard let transport, let engine else { return }
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
            refresh()
            let stamp = Date().formatted(date: .omitted, time: .shortened)
            syncStatus = "Synced \(stamp): \(s.pushed) up, \(s.pulled) down" + (s.deleted > 0 ? ", \(s.deleted) deleted" : "")
                + (s.failed > 0 ? ", \(s.failed) failed" : "")
        } catch {
            syncStatus = "Sync problem: \(error.localizedDescription)"
        }
    }

    /// Called after every local write: sync two seconds after the last one.
    func scheduleSync() {
        debouncedSync?.cancel()
        debouncedSync = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.syncNow(reason: "local change")
        }
    }

    static let defaultDatabaseURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Stint/stint.sqlite")

    static var databaseURL: URL {
        migrateFromTimetracker()
        if let p = UserDefaults.standard.string(forKey: "databasePath"), !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        return defaultDatabaseURL
    }

    /// The app was called Timetracker before 0.1.0: carry over its preferences and move its
    /// data folder to the new name, once, when the new folder does not exist yet.
    private static func migrateFromTimetracker() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldFolder = support.appending(path: "Timetracker")
        let newFolder = defaultDatabaseURL.deletingLastPathComponent()
        if UserDefaults.standard.object(forKey: "databasePath") == nil,
           let old = UserDefaults(suiteName: "io.artnim.timetracker")?.string(forKey: "databasePath"), !old.isEmpty {
            UserDefaults.standard.set(old, forKey: "databasePath")
        }
        guard fm.fileExists(atPath: oldFolder.appending(path: "timetracker.sqlite").path),
              !fm.fileExists(atPath: newFolder.path) else { return }
        do {
            try fm.moveItem(at: oldFolder, to: newFolder)
            try fm.moveItem(at: newFolder.appending(path: "timetracker.sqlite"), to: defaultDatabaseURL)
        } catch {
            NSLog("Stint: could not move the Timetracker data folder: \(error)")
        }
    }

    init(db: AppDatabase) {
        self.db = db
        refresh()
        if let r = running, r.startUTC < Date().addingTimeInterval(-12 * 3600) {
            staleRunning = r
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
    }

    /// Opens the configured database; on a migration failure shows the error and quits (spec §7).
    static func load() -> AppState {
        do {
            let state = AppState(db: try AppDatabase.open(at: databaseURL))
            state.startSync()
            return state
        } catch {
            let alert = NSAlert()
            alert.messageText = "Stint cannot open its database"
            alert.informativeText = "\(databaseURL.path)\n\n\(error)"
            alert.runModal()
            NSApplication.shared.terminate(nil)
            exit(1)
        }
    }

    func reopen(at url: URL) throws {
        db = try AppDatabase.open(at: url)
        UserDefaults.standard.set(url.path, forKey: "databasePath")
        let transport = CloudKitTransport(database: db)
        self.transport = transport
        engine = SyncEngine(database: db, transport: transport)
        refresh()
        scheduleSync()
    }

    func refresh() {
        defer { dataVersion += 1 }
        do {
            running = try db.runningEntry()
            recents = try db.recents(limit: 10)
            projects = try db.allProjects()
            clients = try db.allClients()
            repos = try db.allRepos()
            issueRows = try db.openIssueRows()
            allIssueRows = try db.searchIssueRows(closedSince: Self.closedSearchCutoff)
        } catch {
            lastError = "\(error)"
        }
    }

    /// Fetches the issues assigned to you with every configured account, plus every open issue of
    /// each tracked repository (trying the accounts in order until one can read it), and merges
    /// them. Issues missing from the merged result are closed only when everything succeeded, so
    /// one failing token or unreadable repo never hides another organisation's issues.
    func syncIssues() async {
        let accounts = KeychainStore.githubAccounts()
        guard !accounts.isEmpty else {
            githubError = "No GitHub token. Add one in Settings → GitHub."
            return
        }
        let cutoff = Self.closedSearchCutoff
        var assigned: [GitHubIssue] = []
        var rejected: [String] = []
        var failed = 0
        for account in accounts {
            do {
                let client = GitHubClient(token: account.token)
                assigned += try await client.assignedIssues()
                assigned += try await client.assignedIssues(state: "closed", since: cutoff)
            } catch GitHubError.unauthorized {
                rejected.append(account.label)
                failed += 1
            } catch {
                failed += 1   // offline or rate-limited: keep the cache, stay quiet (spec §3)
            }
        }
        let usable = accounts.filter { !rejected.contains($0.label) }
        var listed: [GitHubIssue] = []
        for repo in (try? db.allRepos()) ?? [] {
            var fetched = false
            for account in usable {
                do {
                    let client = GitHubClient(token: account.token)
                    listed += try await client.repoIssues(owner: repo.owner, name: repo.name)
                    listed += try await client.repoIssues(owner: repo.owner, name: repo.name,
                                                          state: "closed", since: cutoff, maxPages: 2)
                    fetched = true
                    break
                } catch GitHubError.http(let code) where code == 403 || code == 404 {
                    continue   // this token cannot see the repo; try the next account
                } catch {
                    break      // unauthorized, offline, rate-limited: do not hammer the API
                }
            }
            if !fetched { failed += 1 }
        }
        let merged = IssueSync.merge(assigned: assigned, repoIssues: listed)
        if !merged.isEmpty || failed == 0 {
            do {
                try IssueSync.apply(merged, to: db, closeMissing: failed == 0)
                refresh()
            } catch {
                lastError = "\(error)"
            }
        }
        githubError = rejected.isEmpty ? nil
            : "GitHub rejected the token for \(rejected.joined(separator: ", ")) (401). Check Settings → GitHub."
    }

    /// Tracks "owner/name" so its open issues are searchable before anything is assigned to you.
    func addRepo(fullName: String) {
        perform { try db.addRepo(fullName: fullName) }
        if lastError == nil { Task { await syncIssues() } }
    }

    func startIssue(_ row: IssueRow) {
        perform {
            try db.start(description: "#\(row.issue.number): \(row.issue.title)", projectId: row.repo.projectId,
                         repoId: row.repo.id, issueNumber: row.issue.number, issueTitle: row.issue.title)
        }
    }

    func assignRepo(_ repoId: Int64, to projectId: Int64?) {
        perform { try db.assignRepo(repoId, toProject: projectId) }
    }

    @discardableResult
    func createProject(named name: String, clientId: Int64?) -> Int64? {
        var p = Project(clientId: clientId, name: name)
        perform { try db.insert(&p) }
        return p.id
    }

    func createClient(named name: String) {
        var c = Client(name: name)
        perform { try db.insert(&c) }
    }

    func deleteClient(_ c: Client) {
        perform { try db.delete(c) }     // projects keep existing with clientId = NULL
    }

    func deleteProject(_ p: Project) {
        perform { try db.delete(p) }     // entries and repos keep existing with projectId = NULL
    }

    func updateProject(_ p: Project) {
        perform { try db.update(p) }
    }

    var userName: String {
        get { (try? db.setting("userName")) ?? "" }
        set { try? db.setSetting("userName", newValue); scheduleSync() }
    }

    func projectName(_ id: Int64?) -> String {
        projects.first { $0.id == id }?.name ?? ""
    }

    func elapsed(_ e: Entry) -> String {
        let s = Int(max(0, now.timeIntervalSince(e.startUTC)))
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    var menuTitle: String {
        guard let r = running else { return "" }
        let tag = r.issueNumber.map { "#\($0)" } ?? projectName(r.projectId)
        return tag.isEmpty ? elapsed(r) : "\(elapsed(r)) \(tag)"
    }

    func start(_ item: RecentItem) {
        perform { try db.start(description: item.description, projectId: item.projectId, repoId: item.repoId,
                               issueNumber: item.issueNumber, issueTitle: item.issueTitle) }
    }

    func startNew(description: String, projectId: Int64?) {
        perform { try db.start(description: description, projectId: projectId) }
    }

    func stop() {
        perform { try db.stopRunning() }
    }

    func stopRunning(at date: Date) {
        perform { try db.stopRunning(at: date) }
        staleRunning = nil
    }

    func updateRunningDescription(_ text: String) {
        guard let current = running, current.description != text else { return }
        perform {
            guard var r = try db.runningEntry() else { return }   // never write a stale in-memory record
            r.description = text
            try db.update(r)
        }
    }

    func perform(_ block: () throws -> Void) {
        do { try block(); lastError = nil } catch { lastError = "\(error)" }
        refresh()
        scheduleSync()
    }

    func entries(year: Int, month: Int) -> [Entry] {
        let (s, e) = monthRange(year: year, month: month, calendar: .current)
        return (try? db.entries(from: s, to: e)) ?? []
    }

    /// Returns false (and sets lastError) when end is not after start.
    @discardableResult
    func update(_ entry: Entry) -> Bool {
        if let end = entry.endUTC, end <= entry.startUTC {
            lastError = "End must be after start."
            return false
        }
        perform { try db.update(entry) }
        return lastError == nil
    }

    func delete(_ entry: Entry) {
        perform { try db.delete(entry) }
    }

    func addEntry(on day: Date) {
        let cal = Calendar.current
        let start = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        var e = Entry(description: "", startUTC: start, endUTC: start.addingTimeInterval(3600))
        perform { try db.insert(&e) }
    }
}
