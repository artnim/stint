import SwiftUI
import TimeCore

struct PopoverView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var newDescription = ""
    @State private var newProjectId: Int64?

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 10) {
            if let r = state.running {
                RunningView(entry: r)
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
                    issueSections   // filled in Task 14; empty for now
                }
            }
            .frame(maxHeight: 420)
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

    @ViewBuilder private var issueSections: some View { EmptyView() }

    private var newEntryRow: some View {
        HStack {
            TextField("New entry…", text: $newDescription).textFieldStyle(.roundedBorder)
            Picker("", selection: $newProjectId) {
                Text("No project").tag(Int64?.none)
                ForEach(state.projects) { p in Text(p.name).tag(Int64?.some(p.id!)) }
            }
            .labelsHidden().frame(width: 130)
            Button("Start") {
                state.startNew(description: newDescription, projectId: newProjectId)
                newDescription = ""
            }
            .disabled(newDescription.isEmpty && newProjectId == nil)
        }
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
                    .keyboardShortcut(.defaultAction)
            }
            Text(state.projectName(entry.projectId)).font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { text = entry.description }
    }
}
