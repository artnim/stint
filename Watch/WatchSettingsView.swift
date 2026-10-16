import SwiftUI
import TimeCore

struct WatchSettingsView: View {
    @Environment(WatchState.self) private var state

    var body: some View {
        NavigationStack {
            List {
                Section("iCloud sync") {
                    Text(state.syncStatus).font(.caption2)
                    Text(PushDiagnostics.summary).font(.caption2).foregroundStyle(.secondary)
                    Text(ComplicationStore.timelineSummary).font(.caption2).foregroundStyle(.secondary)
                    Button("Sync now") { Task { await state.syncNow(reason: "manual") } }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
