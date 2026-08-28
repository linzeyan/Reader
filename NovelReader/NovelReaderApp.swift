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
        Self.sizeTheImageCache()
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

    /// Gives `URLCache.shared` room for comic pages.
    ///
    /// It comes up sized for what this app used to fetch over `URLSession` — cover
    /// thumbnails — which measured 512KB in memory and 10MB on disk on the simulator. A
    /// comic chapter is 5–20MB, so at that size one chapter evicts the one before it and
    /// "read it again for free" is untrue of anything but the page just turned.
    ///
    /// 32MB in memory is roughly two chapters, which is the window the reader is
    /// actually moving through. 512MB on disk is a few dozen chapters — generous, and
    /// deliberately so: it is the difference between re-reading last night's chapter
    /// offline and fetching it again. It costs nothing until it is used, iOS may reclaim
    /// it under pressure, and "settings → clear cache" already empties it (`WebCache`).
    ///
    /// Set here, before any request can be made. `URLCache.shared` is read by the first
    /// `URLSession.shared` task, and replacing it afterwards leaves that task's
    /// responses in a cache nothing will look in again.
    private static func sizeTheImageCache() {
        URLCache.shared = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024
        )
    }
}
