import SwiftUI
import TimeCore

struct WatchSettingsView: View {
    @Environment(WatchState.self) private var state

    var body: some View {
        NavigationStack {
            List {
                Section("iCloud sync") {
                    Text(state.syncStatus).font(.caption2)
                    Button("Sync now") { Task { await state.syncNow(reason: "manual") } }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
