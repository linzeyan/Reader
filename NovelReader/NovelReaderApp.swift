import SwiftUI

@main
struct NovelReaderApp: App {
    /// For the work that has to be done before launch finishes: the image cache sized
    /// before the first request, and installed faces restored before a page is laid out.
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
        // Before a page can be composed. Access to a face the reader installed is granted
        // per process, so the name stored last night resolves to nothing until this has
        // been answered — and a book opened in that window is laid out in the system face
        // with no sign that anything went wrong. See `InstalledFonts`.
        InstalledFonts.restore(into: .shared)
        #if DEBUG
        TouchIndicator.armIfRequested()
        #endif
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
