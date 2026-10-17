import SwiftUI
import TimeCore

struct MobileEntriesView: View {
    @Environment(MobileState.self) private var state
    @State private var reload = 0
    @State private var pendingDelete: [Entry]?

    private struct DayGroup: Identifiable { let day: Day; let entries: [Entry]; var id: Day { day } }
    private var days: [DayGroup] {
        _ = reload
        var order: [Day] = []; var groups: [Day: [Entry]] = [:]
        for e in state.windowEntries().reversed() {
            let d = Day(e.startUTC, calendar: .current)
            if groups[d] == nil { order.append(d) }
            groups[d, default: []].append(e)
        }
        return order.map { DayGroup(day: $0, entries: groups[$0]!) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(days) { group in
                    let entries = group.entries
                    Section(fmtDate(group.day, .en)) {
                        ForEach(entries) { e in
                            NavigationLink { EntryEditor(entry: e) { reload += 1 } } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(e.description.isEmpty ? "—" : e.description).lineLimit(1)
                                        Text(state.projectName(e.projectId)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(e.hours.map { fmtHours($0, .en) } ?? "running").monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in pendingDelete = offsets.map { entries[$0] } }
                    }
                }
            }
            .navigationTitle("Entries")
            .onChange(of: state.running) { reload += 1 }
            .confirmationDialog("Delete entry?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    pendingDelete?.forEach(state.delete); pendingDelete = nil; reload += 1
                }
            }
        }
    }
}

struct EntryEditor: View {
    @Environment(MobileState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State var entry: Entry
    let onSave: () -> Void
    @State private var tags = ""

    var body: some View {
        Form {
            TextField("Description", text: $entry.description)
            DatePicker("Start", selection: $entry.startUTC)
            if entry.endUTC != nil {
                DatePicker("End", selection: Binding(get: { entry.endUTC ?? Date() }, set: { entry.endUTC = $0 }))
            }
            Picker("Project", selection: $entry.projectId) {
                Text("No project").tag(Int64?.none)
                ForEach(state.projects) { p in Text(p.name).tag(Int64?.some(p.id!)) }
            }
            TextField("Tags, comma separated", text: $tags)
            if let err = state.lastError { Text(err).foregroundStyle(.red) }
        }
        .navigationTitle("Entry")
        .toolbar { Button("Save") { save() } }
        .onAppear { tags = entry.tags.joined(separator: ", "); state.lastError = nil }
    }

    private func save() {
        var e = entry
        e.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        e.startUTC = Date(timeIntervalSince1970: floor(e.startUTC.timeIntervalSince1970 / 60) * 60)
        if let end = e.endUTC { e.endUTC = Date(timeIntervalSince1970: floor(end.timeIntervalSince1970 / 60) * 60) }
        if state.update(e) { onSave(); dismiss() }
    }
}

#Preview {
    MobileEntriesView().environment(MobileState(db: .preview(), syncing: false))
}
