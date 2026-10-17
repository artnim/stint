import SwiftUI
import TimeCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab().tabItem { Label("General", systemImage: "gear") }
            ProjectsSettingsTab().tabItem { Label("Projects", systemImage: "folder") }
            GitHubSettingsTab().tabItem { Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
            ImportSettingsTab().tabItem { Label("Import", systemImage: "square.and.arrow.down") }
        }
        .frame(width: 680, height: 480)
    }
}

struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var state
    @State private var name = ""
    @State private var dbMessage = ""

    var body: some View {
        Form {
            TextField("Your name (shown on reports)", text: $name)
                .onSubmit { if name != state.userName { state.userName = name } }
                .onChange(of: name) { if name != state.userName { state.userName = name } }
            LabeledContent("Database") {
                VStack(alignment: .leading) {
                    Text(AppState.databaseURL.path).textSelection(.enabled).font(.caption)
                    HStack {
                        Button("Choose folder…") { chooseFolder() }
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppState.databaseURL]) }
                        Button("Use default") { reopen(AppState.defaultDatabaseURL) }
                    }
                    Text(dbMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent("iCloud sync") {
                HStack {
                    Text(state.syncStatus).font(.caption)
                    Button("Sync now") { Task { await state.syncNow(reason: "manual") } }
                }
            }
        }
        .padding()
        .onAppear { name = state.userName }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        reopen(dir.appending(path: "stint.sqlite"))
    }

    /// Opens (or creates) the database at `url`; the previous file is left where it is.
    private func reopen(_ url: URL) {
        let existed = FileManager.default.fileExists(atPath: url.path)
        do {
            if !existed {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try state.db.backup(to: url)
            }
        } catch {
            dbMessage = "Could not copy the database: \(error)"
            return
        }
        do {
            try state.reopen(at: url)
            dbMessage = existed
                ? "Now using \(url.path). The previous file was not moved."
                : "Copied the current database to \(url.path) and switched to it."
        } catch {
            dbMessage = "Could not open: \(error)"
        }
    }
}

#Preview {
    SettingsView().environment(AppState(db: .preview()))
}
