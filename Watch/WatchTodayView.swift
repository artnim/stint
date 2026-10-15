import SwiftUI
import TimeCore

struct WatchTodayView: View {
    @Environment(WatchState.self) private var state
    @State private var pendingDelete: Entry?

    var body: some View {
        NavigationStack {
            List {
                if state.today.isEmpty { Text("Nothing today").foregroundStyle(.secondary) }
                ForEach(state.today) { e in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(e.description.isEmpty ? "—" : e.description).lineLimit(2)
                            Text(state.projectName(e.projectId)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if e.endUTC == nil { Text("running").font(.caption2).foregroundStyle(.tint) }
                        else { Text(fmtHours(e.hours ?? 0, .en)).monospacedDigit().font(.caption).foregroundStyle(.secondary) }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { pendingDelete = e } }
                }
            }
            .navigationTitle("Today")
            .confirmationDialog("Delete entry?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) { if let e = pendingDelete { state.delete(e) }; pendingDelete = nil }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            }
        }
    }
}
