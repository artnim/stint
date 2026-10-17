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
                Button("Add entry") { state.addEntry(on: addDay); reloadToken += 1 }
                if let err = state.lastError { Text(err).foregroundStyle(.red).font(.caption) }
            }
            .padding(10)
            Divider()
            List {
                ForEach(days) { group in
                    Section {
                        ForEach(group.entries) { e in
                            // a stop or start elsewhere rebuilds the row: its editing copy could keep showing "running"
                            EntryRow(entry: e) { reloadToken += 1 }.id("\(e.id ?? 0)-\(e.endUTC == nil)")
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

    /// Today when the current month is shown, otherwise the first day of the shown month.
    private var addDay: Date {
        let cal = Calendar.current
        let now = Date()
        if cal.component(.year, from: now) == year && cal.component(.month, from: now) == month { return now }
        return monthRange(year: year, month: month, calendar: cal).start
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
    let source: Entry                 // the parent's current DB value
    let onChange: () -> Void
    @State private var entry: Entry
    @State private var tagsText: String
    @State private var reverting = false
    @State private var confirmDelete = false

    init(entry: Entry, onChange: @escaping () -> Void) {
        source = entry
        self.onChange = onChange
        _entry = State(initialValue: entry)
        _tagsText = State(initialValue: entry.tags.joined(separator: ", "))
    }

    /// Drops seconds and sub-seconds so hidden precision cannot tip report rounding.
    private func wholeMinute(_ d: Date) -> Date {
        Date(timeIntervalSince1970: floor(d.timeIntervalSince1970 / 60) * 60)
    }

    private func minuteBinding(_ keyPath: WritableKeyPath<Entry, Date>) -> Binding<Date> {
        Binding(get: { entry[keyPath: keyPath] },
                set: { entry[keyPath: keyPath] = wholeMinute($0) })
    }

    var body: some View {
        HStack(spacing: 8) {
            DatePicker("", selection: minuteBinding(\.startUTC), displayedComponents: [.date, .hourAndMinute])
                .labelsHidden().frame(width: 170)
            if entry.endUTC != nil {
                DatePicker("", selection: Binding(get: { entry.endUTC ?? Date() }, set: { entry.endUTC = wholeMinute($0) }),
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
        .onChange(of: source) { _, new in
            // external change (timer stopped, edit elsewhere): re-seed without writing back
            if new != entry {
                reverting = true
                entry = new
            }
            tagsText = new.tags.joined(separator: ", ")
        }
        .onChange(of: entry) { _, new in
            if reverting { reverting = false; return }
            if state.update(new) {
                onChange()
            } else {
                // rejected (end must be after start): revert to the DB value, keep the error visible
                reverting = true
                entry = source
            }
        }
    }
}

#Preview {
    EntriesView().environment(AppState(db: .preview())).frame(width: 900, height: 600)
}
