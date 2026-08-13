import BackgroundTasks
import SwiftUI

@main
struct NovelReaderApp: App {
    /// The only reason this app has a delegate: `BGTaskScheduler` requires every
    /// identifier to be registered before launch finishes, and SwiftUI's
    /// `backgroundTask` modifier covers app refresh and URLSession tasks but not
    /// processing tasks — which is the kind a paced, WKWebView-driven download
    /// needs, because it takes minutes rather than seconds.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // `using: .main` rather than the default private queue: everything the
        // handler touches — the download queue, the fetcher's one web view — is
        // main-actor state, so the alternative is a hop that has to smuggle a
        // non-Sendable `BGTask` across it.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundDownloads.identifier, using: .main
        ) { task in
            MainActor.assumeIsolated {
                guard let env = AppEnvironment.live else {
                    // A background launch connects no scene, so no view has built
                    // the object graph — and the WKWebView the fetching goes
                    // through needs a window. The queue survives on disk and the
                    // next launch picks it up; recorded rather than silently
                    // skipped, because "iOS woke us and we could not use it" and
                    // "iOS never woke us" are different problems.
                    BackgroundDownloads.recordDeferredToLaunch()
                    task.setTaskCompleted(success: false)
                    return
                }
                env.backgroundDownloads.run(task: task)
            }
        }
        return true
    }
}
