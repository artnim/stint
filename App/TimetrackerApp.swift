import SwiftUI
import TimeCore

@main
struct TimetrackerApp: App {
    @State private var state = AppState.load()

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environment(state)
        } label: {
            Label(state.menuTitle, systemImage: state.running == nil ? "clock" : "timer")
                .labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.window)

        Window("Entries", id: "entries") {
            EntriesView().environment(state)
        }
        .defaultSize(width: 900, height: 600)

        Window("Reports", id: "reports") {
            ReportsView().environment(state)
        }
        .defaultSize(width: 1100, height: 760)

        Settings {
            SettingsView().environment(state)
        }
    }
}
