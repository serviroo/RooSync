import BackgroundTasks
import SwiftUI

@main
struct RooSyncApp: App {
    @UIApplicationDelegateAdaptor(RooSyncAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

@MainActor
final class RooSyncAppDelegate: NSObject, UIApplicationDelegate {
    private let refreshIdentifier = "com.rooindustries.roosync.refresh"
    private let processingIdentifier = "com.rooindustries.roosync.processing"

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        registerBackgroundTasks()
        scheduleRefresh()
        scheduleProcessing()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        scheduleRefresh()
        scheduleProcessing()
    }

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshIdentifier, using: nil) { task in
            self.run(task)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingIdentifier, using: nil) { task in
            self.run(task)
        }
    }

    private func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: processingIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 60 * 60)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        try? BGTaskScheduler.shared.submit(request)
    }

    private func run(_ task: BGTask) {
        let work = Task { @MainActor in
            let completed = await SyncStore.shared.syncNow(window: .seconds(15))
            task.setTaskCompleted(success: completed)
            self.scheduleRefresh()
            self.scheduleProcessing()
        }
        task.expirationHandler = {
            work.cancel()
        }
    }
}
