import SwiftUI
import TimeCore

struct PopoverView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var newDescription = ""
    @State private var newProjectId: Int64?
    @State private var listHeight: CGFloat = 0

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 10) {
            if let r = state.running {
                RunningView(entry: r).id(r.id)
                Divider()
            }
            TextField("Search", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    newEntryRow
                    if !filteredRecents.isEmpty {
                        sectionHeader("Recent")
                        ForEach(filteredRecents, id: \.self) { item in
                            Button { state.start(item) } label: {
                                HStack {
                                    Text(item.description.isEmpty ? "—" : item.description).lineLimit(1)
                                    Spacer()
                                    Text(state.projectName(item.projectId)).foregroundStyle(.secondary).font(.caption)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    issueSections
                }
                // A ScrollView has no intrinsic height, and the MenuBarExtra window sizes
                // itself to the ideal size, so it collapsed to zero. Measure the content instead.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: min(max(listHeight, 1), 420))
            if let err = state.lastError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            Divider()
            HStack {
                Button("Entries…") { open("entries") }
                Button("Reports…") { open("reports") }
                SettingsLink { Text("Settings…") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .font(.caption)
        }
        .padding(12)
        .frame(width: 380)
        .task { await state.syncIssues() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                await state.syncIssues()
            }
        }
        .sheet(item: $state.staleRunning) { entry in
            StaleTimerSheet(entry: entry)
        }
    }

    private var filteredRecents: [RecentItem] {
        let q = query.lowercased()
        return q.isEmpty ? state.recents : state.recents.filter {
            $0.description.lowercased().contains(q) || state.projectName($0.projectId).lowercased().contains(q)
        }
    }

    @ViewBuilder private var issueSections: some View {
        if let err = state.githubError {
            HStack {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(err).font(.caption)
                Spacer()
                SettingsLink { Text("Settings").font(.caption) }
            }
            .padding(.top, 6)
        }
        ForEach(groupedIssues) { group in
            let name = group.name
            sectionHeader(name ?? "Unmapped")
            ForEach(group.rows) { row in
                HStack {
                    Button { state.startIssue(row) } label: {
                        HStack {
                            Image(systemName: row.issue.isPullRequest ? "arrow.triangle.pull" : "circle.dotted")
                                .foregroundStyle(.secondary)
                            Text(verbatim: "#\(row.issue.number)").monospacedDigit().foregroundStyle(.secondary)
                            Text(row.issue.title).lineLimit(1)
                            if row.issue.state == "closed" {
                                Text("closed").font(.caption2).foregroundStyle(.tertiary)
                            }
                            if !row.issue.assignedToMe {
                                Text("unassigned").font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if name == nil { Text(row.repo.fullName).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .buttonStyle(.plain)
                    if name == nil {
                        Menu("Assign") {
                            ForEach(state.projects) { p in
                                Button(p.name) { state.assignRepo(row.repo.id!, to: p.id) }
                            }
                            Divider()
                            Button("New project \"\(row.repo.name)\"") {
                                let id = state.createProject(named: row.repo.name, clientId: nil)
                                state.assignRepo(row.repo.id!, to: id)
                            }
                        }
                        .menuStyle(.borderlessButton).frame(width: 70)
                    }
                }
            }
        }
    }

    private struct IssueGroup: Identifiable {
        let name: String?
        let rows: [IssueRow]
        var id: String { name ?? "\u{0}unmapped" }
    }

    /// Mapped projects first (as `openIssueRows` orders them), then one "Unmapped" group.
    /// Without a query only open issues assigned to you; a query searches every cached open issue
    /// plus those closed in the last 30 days.
    private var groupedIssues: [IssueGroup] {
        let q = query.lowercased()
        let rows = q.isEmpty ? state.issueRows : state.allIssueRows.filter {
            $0.issue.title.lowercased().contains(q) || "#\($0.issue.number)".contains(q) || $0.repo.fullName.lowercased().contains(q)
        }
        var order: [String?] = []
        var groups: [String?: [IssueRow]] = [:]
        for r in rows {
            if groups[r.projectName] == nil { order.append(r.projectName) }
            groups[r.projectName, default: []].append(r)
        }
        return order.map { IssueGroup(name: $0, rows: groups[$0]!) }
    }

    private var newEntryRow: some View {
        HStack {
            TextField("New entry…", text: $newDescription).textFieldStyle(.roundedBorder)
                .onSubmit { startNew() }
            Picker("", selection: $newProjectId) {
                Text("No project").tag(Int64?.none)
                ForEach(state.projects) { p in Text(p.name).tag(Int64?.some(p.id!)) }
            }
            .labelsHidden().frame(width: 130)
            Button("Start") { startNew() }
            .disabled(newDescription.isEmpty && newProjectId == nil)
        }
    }

    private func startNew() {
        guard !(newDescription.isEmpty && newProjectId == nil) else { return }
        state.startNew(description: newDescription, projectId: newProjectId)
        newDescription = ""
    }

    func sectionHeader(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct RunningView: View {
    @Environment(AppState.self) private var state
    let entry: Entry
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Description", text: $text)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .onSubmit { state.updateRunningDescription(text) }
                Spacer()
                Text(state.elapsed(entry)).monospacedDigit().font(.headline)
                Button("Stop") { state.updateRunningDescription(text); state.stop() }
            }
            Text(state.projectName(entry.projectId)).font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { text = entry.description }
        .onChange(of: entry.description) { _, new in text = new }
    }
}
