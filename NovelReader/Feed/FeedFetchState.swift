import Foundation
import GRDB

/// What one device remembers about its last request for a feed, so the next one can ask
/// whether anything has changed instead of asking for the whole document again.
///
/// This is the entire politeness budget of a feed reader. A shelf of forty feeds checked
/// on every launch is forty requests, and a conditional one that ends in `304 Not
/// Modified` costs the publisher a few hundred bytes instead of a few hundred kilobytes.
/// Publishers notice, and readers that do not do this are the reason some feeds are
/// behind a rate limit.
///
/// Local to this device and never synced — see the `v10.feeds` migration for why an ETag
/// must not travel to a device that has never made the request it describes.
struct FeedFetchState: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "feedFetchState"

    var bookId: String
    /// The `ETag` header exactly as it arrived, quotes, `W/` prefix and all.
    ///
    /// Stored verbatim and echoed back verbatim: an ETag is an opaque token, and a
    /// server comparing it against one this app "tidied up" would answer that the feed
    /// has changed every single time — which is the failure that looks like nothing at
    /// all going wrong while the whole point of the header is lost.
    var etag: String?
    /// The `Last-Modified` header as text rather than as a `Date`, for the same reason:
    /// it goes back out as `If-Modified-Since` and has to be the same string. Parsing it
    /// into a date and formatting it again is a round trip through two timezone
    /// conventions to arrive at bytes the server never sent.
    var lastModified: String?
    /// When this device last asked, whatever the answer was — including `304`, which is
    /// a successful check that changed nothing. `Book.catalogUpdatedAt` cannot say this:
    /// it means "when the catalog last changed", and a feed that has published nothing
    /// for a month would otherwise look like a feed nobody has checked for a month.
    var checkedAt: Date?
    /// The oldest article the publisher's document still listed, last time one came back.
    ///
    /// The line retention will not delete past. A feed document is a window, and an
    /// article deleted while it is still inside that window is fetched again on the next
    /// refresh and marked unread again — every launch, for ever. Nil for a feed whose
    /// document this device has never parsed, and then nothing of it is purged at all,
    /// which is the safe direction.
    var windowOldestAt: Date?
}
