import AppKit
import Foundation
import Observation
import TimeCore

@Observable @MainActor
final class AppState {
    private(set) var db: AppDatabase
    var running: Entry?
    var recents: [RecentItem] = []
    var projects: [Project] = []
    var clients: [Client] = []
    var repos: [Repo] = []
    var now = Date()
    var staleRunning: Entry?
    var lastError: String?
    var issueRows: [IssueRow] = []
    var githubError: String?

    private var ticker: Timer?

    static let defaultDatabaseURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Timetracker/timetracker.sqlite")

    static var databaseURL: URL {
        if let p = UserDefaults.standard.string(forKey: "databasePath"), !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        return defaultDatabaseURL
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
            return AppState(db: try AppDatabase.open(at: databaseURL))
        } catch {
            let alert = NSAlert()
            alert.messageText = "Timetracker cannot open its database"
            alert.informativeText = "\(databaseURL.path)\n\n\(error)"
            alert.runModal()
            NSApplication.shared.terminate(nil)
            exit(1)
        }
    }

    func reopen(at url: URL) throws {
        db = try AppDatabase.open(at: url)
        UserDefaults.standard.set(url.path, forKey: "databasePath")
        refresh()
    }

    func refresh() {
        do {
            running = try db.runningEntry()
            recents = try db.recents(limit: 10)
            projects = try db.allProjects()
            clients = try db.allClients()
            repos = try db.allRepos()
            issueRows = try db.openIssueRows()
        } catch {
            lastError = "\(error)"
        }
    }

    func syncIssues() async {
        guard let token = KeychainStore.read(KeychainStore.tokenAccount), !token.isEmpty else {
            githubError = "No GitHub token. Add one in Settings → GitHub."
            return
        }
        do {
            let issues = try await GitHubClient(token: token).assignedIssues()
            try IssueSync.apply(issues, to: db)
            githubError = nil
            refresh()
        } catch GitHubError.unauthorized {
            githubError = "GitHub rejected the token (401). Check Settings → GitHub."
        } catch {
            // offline or rate-limited: keep the cache, stay quiet (spec §3)
        }
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
        set { try? db.setSetting("userName", newValue); }
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
        guard var r = running, r.description != text else { return }
        r.description = text
        perform { try db.update(r) }
    }

    func perform(_ block: () throws -> Void) {
        do { try block(); lastError = nil } catch { lastError = "\(error)" }
        refresh()
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
