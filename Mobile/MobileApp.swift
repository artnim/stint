import SwiftUI
import TimeCore
import UIKit

final class MobileAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard CloudKitTransport.isSyncNotification(userInfo) else { completionHandler(.noData); return }
        PushDiagnostics.received()
        Task { @MainActor in await MobileState.shared?.syncNow(reason: "push"); completionHandler(.newData) }
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushDiagnostics.registered()
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushDiagnostics.failed(error)
    }
}

@main
struct MobileApp: App {
    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var delegate
    @State private var state = MobileState.load()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                StintView().tabItem { Label("Stint", systemImage: "timer") }
                MobileEntriesView().tabItem { Label("Entries", systemImage: "list.bullet") }
                MobileSettingsView().tabItem { Label("Settings", systemImage: "gear") }
            }
            .environment(state)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await state.syncNow(reason: "foreground"); await state.syncIssues() } }
            if phase == .background { syncInBackground() }
        }
    }

    /// Finishes pending writes (a stop, then locking the phone) before iOS suspends the app.
    private func syncInBackground() {
        let app = UIApplication.shared
        let task = BackgroundTask()
        task.id = app.beginBackgroundTask(withName: "Stint sync") { task.end() }
        Task { @MainActor in
            await state.syncNow(reason: "background")
            task.end()
        }
    }
}

/// Ends a background task exactly once, from whichever comes first: the sync or the expiration handler.
private final class BackgroundTask {
    var id = UIBackgroundTaskIdentifier.invalid
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
