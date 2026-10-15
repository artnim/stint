import SwiftUI
import TimeCore

struct WatchStintView: View {
    @Environment(WatchState.self) private var state

    var body: some View {
        NavigationStack {
            List {
                if let r = state.running {
                    Section {
                        // one card: what, for whom, how long
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.description.isEmpty ? "—" : r.description).font(.headline).lineLimit(2)
                            let project = state.projectName(r.projectId)
                            if !project.isEmpty {
                                Text(project).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Text(r.startUTC, style: .timer).font(.title2).monospacedDigit()
                        }
                        .padding(.vertical, 4)
                        Button(role: .destructive) { Task { await state.stop() } } label: {
                            Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                        }
                    }
                } else {
                    Section {
                        Text("Nothing running").foregroundStyle(.secondary)
                        if let last = state.lastFinished {
                            Button { Task { await state.restartLast() } } label: {
                                VStack(alignment: .leading) {
                                    Text("Restart last").font(.headline)
                                    Text(last.description.isEmpty ? "—" : last.description).font(.caption2).lineLimit(1)
                                }
                            }
                        }
                    }
                }
                if !state.recents.isEmpty {
                    Section("Recent") {
                        ForEach(state.recents, id: \.self) { item in
                            Button { Task { await state.start(item) } } label: {
                                VStack(alignment: .leading) {
                                    Text(item.description.isEmpty ? "—" : item.description).lineLimit(2)
                                    Text(state.projectName(item.projectId)).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                ForEach(groups) { group in
                    Section(group.name ?? "Unmapped") {
                        ForEach(group.rows) { row in
                            Button { Task { await state.startIssue(row) } } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: row.issue.isPullRequest ? "arrow.triangle.pull" : "circle.dotted").foregroundStyle(.secondary)
                                    Text(verbatim: "#\(row.issue.number)").monospacedDigit().foregroundStyle(.secondary)
                                    Text(row.issue.title).lineLimit(2)
                                }
                            }
                        }
                    }
                }
                if let err = state.lastError { Text(err).font(.caption2).foregroundStyle(.red) }
            }
            .navigationTitle("Stint")
            .sensoryFeedback(.success, trigger: state.running?.uuid)
        }
    }

    private struct IssueGroup: Identifiable { let name: String?; let rows: [IssueRow]; var id: String { name ?? "\u{0}" } }
    private var groups: [IssueGroup] {
        var order: [String?] = []; var byName: [String?: [IssueRow]] = [:]
        for r in state.issueRows { if byName[r.projectName] == nil { order.append(r.projectName) }; byName[r.projectName, default: []].append(r) }
        return order.map { IssueGroup(name: $0, rows: byName[$0]!) }
    }
}
