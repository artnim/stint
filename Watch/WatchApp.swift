import SwiftUI
import TimeCore
import WatchKit

final class WatchDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        Self.scheduleRefresh()
        WKApplication.shared().registerForRemoteNotifications()   // R19: CloudKit's zone pushes trigger a sync
    }

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) { PushDiagnostics.registered() }
    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) { PushDiagnostics.failed(error) }

    /// A silent CloudKit push: another device changed something. Sync, which also refreshes the complication.
    func didReceiveRemoteNotification(_ userInfo: [AnyHashable: Any],
                                      fetchCompletionHandler completionHandler: @escaping (WKBackgroundFetchResult) -> Void) {
        guard CloudKitTransport.isSyncNotification(userInfo) else { completionHandler(.noData); return }
        PushDiagnostics.received()
        Task { @MainActor in
            await WatchState.shared.syncNow(reason: "push")
            completionHandler(.newData)
        }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            guard let refresh = task as? WKApplicationRefreshBackgroundTask else { task.setTaskCompletedWithSnapshot(false); continue }
            Task { @MainActor in
                // pulls, prunes (R17), applies the snapshot (R18), refreshes the complication
                await WatchState.shared.syncNow(reason: "background refresh")
                Self.scheduleRefresh()
                refresh.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    /// R19: about every 30 minutes while the watch is worn; watchOS decides the exact moment.
    static func scheduleRefresh() {
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: Date().addingTimeInterval(30 * 60), userInfo: nil) { _ in }
    }
}

@main
struct WatchApp: App {
    @WKApplicationDelegateAdaptor(WatchDelegate.self) private var delegate
    @State private var state = WatchState.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                WatchStintView()
                WatchTodayView()
                WatchSettingsView()
            }
            .tabViewStyle(.verticalPage)
            .environment(state)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await state.syncNow(reason: "foreground") } }
            if phase == .background { WatchDelegate.scheduleRefresh() }
        }
    }
}
