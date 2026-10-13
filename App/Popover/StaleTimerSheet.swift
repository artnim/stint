import SwiftUI
import TimeCore

struct StaleTimerSheet: View {
    @Environment(AppState.self) private var state
    let entry: Entry
    @State private var stopAt = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A timer has been running since \(entry.startUTC.formatted(date: .abbreviated, time: .shortened)).")
            Text(entry.description).font(.headline)
            DatePicker("Stop at", selection: $stopAt, in: entry.startUTC...Date())
            HStack {
                Button("Keep running") { state.staleRunning = nil }
                Spacer()
                Button("Stop at that time") { state.stopRunning(at: stopAt) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
