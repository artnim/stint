import SwiftUI
import TimeCore

struct EntriesView: View {
    @Environment(AppState.self) private var state
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var month = Calendar.current.component(.month, from: Date())
    @State private var reloadToken = 0

    private struct DayGroup: Identifiable {
        let day: Day
        let entries: [Entry]
        var id: Day { day }
    }

    private var entries: [Entry] { _ = reloadToken; return state.entries(year: year, month: month) }
    private var days: [DayGroup] {
        var order: [Day] = []
        var groups: [Day: [Entry]] = [:]
        for e in entries {
            let d = Day(e.startUTC, calendar: .current)
            if groups[d] == nil { order.append(d) }
            groups[d, default: []].append(e)
        }
        return order.map { DayGroup(day: $0, entries: groups[$0]!) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                Text(monthTitle).font(.headline).frame(width: 180)
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                Spacer()
                Button("Add entry today") { state.addEntry(on: Date()); reloadToken += 1 }
                if let err = state.lastError { Text(err).foregroundStyle(.red).font(.caption) }
            }
            .padding(10)
            Divider()
            List {
                ForEach(days) { group in
                    Section {
                        ForEach(group.entries) { e in
                            EntryRow(entry: e) { reloadToken += 1 }
                        }
                    } header: {
                        HStack {
                            Text(fmtDate(group.day, .en))
                            Spacer()
                            Text(fmtHours(group.entries.compactMap(\.hours).reduce(0, +), .en)).monospacedDigit()
                        }
                    }
                }
            }
        }
        .onChange(of: state.running) { reloadToken += 1 }
    }

    private var monthTitle: String { "\(Strings.of(.en).months[month]) \(year)" }

    private func shift(_ by: Int) {
        var m = month + by, y = year
        if m < 1 { m = 12; y -= 1 }
        if m > 12 { m = 1; y += 1 }
        month = m; year = y
    }
}

struct EntryRow: View {
    @Environment(AppState.self) private var state
    @State var entry: Entry
    let onChange: () -> Void
    @State private var tagsText = ""

    var body: some View {
        HStack(spacing: 8) {
            DatePicker("", selection: $entry.startUTC, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden().frame(width: 170)
            if entry.endUTC != nil {
                DatePicker("", selection: Binding(get: { entry.endUTC ?? Date() }, set: { entry.endUTC = $0 }),
                           displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden().frame(width: 170)
            } else {
                Text("running").foregroundStyle(.secondary).frame(width: 170)
            }
            Picker("", selection: $entry.projectId) {
                Text("No project").tag(Int64?.none)
                ForEach(state.projects) { p in Text(p.name).tag(Int64?.some(p.id!)) }
            }
            .labelsHidden().frame(width: 140)
            TextField("Description", text: $entry.description)
            TextField("tags, comma separated", text: $tagsText)
                .frame(width: 160)
                .onSubmit { entry.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            Text(entry.hours.map { fmtHours($0, .en) } ?? "").monospacedDigit().frame(width: 60, alignment: .trailing)
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .confirmationDialog("Delete this entry?", isPresented: $confirmDelete) {
                    Button("Delete", role: .destructive) { state.delete(entry); onChange() }
                }
        }
        .onAppear { tagsText = entry.tags.joined(separator: ", ") }
        .onChange(of: entry) { _, new in
            if state.update(new) { onChange() }
        }
    }

    @State private var confirmDelete = false
}
