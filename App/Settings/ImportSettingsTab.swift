import SwiftUI
import TimeCore
import UniformTypeIdentifiers

struct ImportSettingsTab: View {
    @Environment(AppState.self) private var state
    @State private var result = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import a solidtime \"detailed\" CSV export. Start/End are read as local time in \(TimeZone.current.identifier). Re-importing the same file adds nothing.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Import CSV…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.commaSeparatedText]
                panel.allowsMultipleSelection = false
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do {
                    let r = try CSVImporter(database: state.db, timeZone: .current).importFile(at: url)
                    result = "Imported \(r.imported), duplicates \(r.skippedDuplicates), breaks \(r.skippedBreaks), unfinished \(r.skippedUnfinished)."
                    state.refresh()
                    state.scheduleSync()
                } catch {
                    result = "Import failed: \(error)"
                }
            }
            Text(result).font(.callout)
            Spacer()
        }
        .padding()
    }
}
