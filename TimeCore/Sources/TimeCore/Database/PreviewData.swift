import Foundation

/// True inside Xcode's preview process. Xcode launches the app's `@main` type behind a preview, so the apps
/// check this to use `AppDatabase.preview()` instead of opening the real database and syncing with iCloud.
public let isRunningForPreviews = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"

extension AppDatabase {
    /// An in-memory database with a little of everything, for SwiftUI previews: a client, a project with a
    /// repo and two assigned issues, three finished entries today and a stint running for 25 minutes.
    /// Never touches the real database or iCloud.
    public static func preview() -> AppDatabase {
        let db = try! AppDatabase.inMemory()
        var client = Client(name: "Altenso")
        try! db.insert(&client)
        var project = Project(clientId: client.id, name: "Altenso SCM")
        try! db.insert(&project)
        let repo = try! db.addRepo(fullName: "artnim/stint")
        try! db.assignRepo(repo.id!, toProject: project.id)
        for (number, title) in [(1427, "Favorites & Images: move API access"), (1452, "Store-owned loading state")] {
            var issue = IssueCache(repoId: repo.id!, number: number, title: title, isPullRequest: false, state: "open", updatedAt: Date())
            try! db.insert(&issue)
        }
        let now = Date()
        let blocks: [(String, Int?, TimeInterval, TimeInterval)] = [   // description, issue, start and end before now (minutes)
            ("Pull request maintenance", nil, 240, 225),
            ("#1452: Store-owned loading state", 1452, 225, 130),
            ("Tool Update Meeting", nil, 120, 60),
        ]
        for (description, issue, from, to) in blocks {
            try! db.start(description: description, projectId: project.id, repoId: issue == nil ? nil : repo.id,
                          issueNumber: issue, at: now.addingTimeInterval(-from * 60))
            try! db.stopRunning(at: now.addingTimeInterval(-to * 60))
        }
        try! db.start(description: "#1427: Favorites & Images: move API access", projectId: project.id, repoId: repo.id,
                      issueNumber: 1427, issueTitle: "Favorites & Images: move API access", at: now.addingTimeInterval(-25 * 60))
        return db
    }
}
