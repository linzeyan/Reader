import Foundation
import WebKit

/// The caches the app fills up without ever being asked to.
///
/// Two of them, from two different systems: `URLCache` holds the cover images
/// `AsyncImage` fetches, and WebKit holds the HTML, CSS, scripts and images of
/// every page the fetcher has loaded. Neither is user data — both are pure
/// speed — so there has to be a way to hand the space back.
///
/// Cookies are deliberately **not** cleared. `cf_clearance` lives there, and
/// dropping it means every source the user has already verified by hand demands
/// verification again. "Free up space" must not silently mean "make the user do
/// the captchas again"; clearing site data is a different action with a
/// different cost, and if it is ever offered it should say so.
@MainActor
enum WebCache {
    /// Everything WebKit keeps for speed. Cookies, local storage and IndexedDB
    /// are absent on purpose — those are state, not cache.
    private static let webKitTypes: Set<String> = [
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeOfflineWebApplicationCache,
        WKWebsiteDataTypeFetchCache,
    ]

    /// Bytes `URLCache` is holding. WebKit's own store reports no size at all
    /// (`fetchDataRecords` returns records, not bytes), so this number covers
    /// the covers and undercounts the pages — which is why the UI labels it as
    /// an image cache rather than claiming to be the total.
    static var imageCacheBytes: Int64 {
        Int64(URLCache.shared.currentDiskUsage + URLCache.shared.currentMemoryUsage)
    }

    static func clear() async {
        URLCache.shared.removeAllCachedResponses()
        await WKWebsiteDataStore.default().removeData(
            ofTypes: webKitTypes, modifiedSince: .distantPast
        )
    }
}
