import SwiftUI
import TimeCore

struct StintView: View {
    @Environment(MobileState.self) private var state
    @State private var query = ""
    @State private var newDescription = ""

    var body: some View {
        NavigationStack {
            List {
                if let r = state.running {
                    Section {
                        VStack(alignment: .leading) {
                            Text(r.description.isEmpty ? "—" : r.description).font(.headline)
                            Text(state.projectName(r.projectId)).font(.caption).foregroundStyle(.secondary)
                            HStack { Text(state.elapsed(r)).monospacedDigit().font(.title2); Spacer(); Button("Stop") { state.stop() }.buttonStyle(.borderedProminent) }
                        }
                    }
                }
                Section {
                    LabeledContent("This month", value: String(format: "%.2f h", state.monthTotal))
                    Text("exact; the report rounds").font(.caption2).foregroundStyle(.tertiary)
                }
                if let err = state.githubError { Section { Text(err).font(.caption).foregroundStyle(.orange) } }
                Section("New") {
                    HStack {
                        TextField("Description", text: $newDescription)
                        Button("Start") { state.startNew(description: newDescription, projectId: nil); newDescription = "" }.disabled(newDescription.isEmpty)
                    }
                }
                if query.isEmpty && !state.recents.isEmpty {
                    Section("Recent") {
                        ForEach(state.recents, id: \.self) { item in
                            Button { state.start(item) } label: {
                                VStack(alignment: .leading) { Text(item.description.isEmpty ? "—" : item.description); Text(state.projectName(item.projectId)).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                ForEach(groups) { group in
                    Section(group.name ?? "Unmapped") {
                        ForEach(group.rows) { row in
                            Button { state.startIssue(row) } label: {
                                HStack {
                                    Text("#\(row.issue.number)").monospacedDigit().foregroundStyle(.secondary)
                                    Text(row.issue.title).lineLimit(2)
                                    if row.issue.state == "closed" { Text("closed").font(.caption2).foregroundStyle(.tertiary) }
                                    if !row.issue.assignedToMe { Text("unassigned").font(.caption2).foregroundStyle(.tertiary) }
                                }
                            }
                        }
                    }
                }
                if !state.syncStatus.isEmpty { Section { Text(state.syncStatus).font(.caption2).foregroundStyle(.tertiary) } }
            }
            .navigationTitle("Stint")
            .searchable(text: $query, prompt: "Search issues")
            .refreshable { await state.syncNow(reason: "pull to refresh"); await state.syncIssues() }
        }
    }

    private struct IssueGroupRow: Identifiable { let name: String?; let rows: [IssueRow]; var id: String { name ?? "\u{0}" } }
    private var groups: [IssueGroupRow] {
        let q = query.lowercased()
        let rows = q.isEmpty ? state.issueRows : state.allIssueRows.filter {
            $0.issue.title.lowercased().contains(q) || "#\($0.issue.number)".contains(q) || $0.repo.fullName.lowercased().contains(q)
        }
        var order: [String?] = []; var byName: [String?: [IssueRow]] = [:]
        for r in rows { if byName[r.projectName] == nil { order.append(r.projectName) }; byName[r.projectName, default: []].append(r) }
        return order.map { IssueGroupRow(name: $0, rows: byName[$0]!) }
    }
}
