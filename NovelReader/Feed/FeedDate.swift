import Foundation

/// Reads the dates feeds publish.
///
/// Two standards, because the formats disagree: RSS 2.0 specifies RFC 822 (`Wed, 02 Oct
/// 2002 08:00:00 GMT`), while Atom and JSON Feed specify RFC 3339, which is ISO 8601
/// (`2002-10-02T08:00:00Z`). A feed is free to carry both — `<pubDate>` beside
/// `<dc:date>` — so nothing can be decided from the format the document is in, and
/// every date is offered to both readers.
///
/// Then there is what publishers actually emit, which is why the list of patterns is
/// longer than the two standards: seconds omitted, the weekday omitted, the timezone
/// omitted, a space where the `T` belongs. A date that will not parse costs the article
/// its place in reading order, so the cheap thing to do is to try the shapes that are
/// known to occur.
enum FeedDate {
    /// The date, or nil for one that no reader recognised.
    ///
    /// Nil is a real answer and callers must keep it: an item with no usable date is
    /// an item whose place in the feed's own order is the only order it has, and
    /// inventing "now" for it would sort every unparseable article to the top on every
    /// refresh — a feed that reshuffles itself each time it is opened.
    static func parse(_ raw: String?) -> Date? {
        guard let text = raw?.nonBlank else { return nil }
        for formatter in iso8601 {
            if let date = formatter.date(from: text) { return date }
        }
        for formatter in patterns {
            if let date = formatter.date(from: text) { return date }
        }
        // Last, and the order is load-bearing rather than incidental: both readers here
        // match a *prefix* rather than the whole string, so one that wants only a date
        // accepts `2002-10-02 08:00:00` and answers midnight. Tried any earlier, it
        // would flatten every timestamp in every feed that writes its dates that way to
        // the start of the day — and an afternoon post would then sort ahead of a
        // morning one, silently, in a list whose whole order is the date.
        return dateOnly.date(from: text)
    }

    /// Built once. A `DateFormatter` costs far more to create than to use, and this
    /// runs once per item across a whole shelf of feeds.
    private static let iso8601: [ISO8601DateFormatter] = {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        // A separate formatter rather than one carrying both options: with
        // `.withFractionalSeconds` set, a date *without* a fraction no longer parses.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [plain, fractional]
    }()

    /// A bare `2002-10-02`, for the feeds that publish a day and no time. Deliberately
    /// alone and deliberately consulted last — see `parse`.
    private static let dateOnly: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()

    private static let patterns: [DateFormatter] = [
        // RFC 822 as RSS specifies it, and the three ways it is routinely trimmed.
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yyyy HH:mm zzz",
        "d MMM yyyy HH:mm:ss zzz",
        "d MMM yyyy HH:mm zzz",
        // No zone at all. Read as GMT below, which is what RFC 822 says to assume.
        "EEE, d MMM yyyy HH:mm:ss",
        "EEE, d MMM yyyy HH:mm",
        "d MMM yyyy HH:mm:ss",
        // Neither standard, and common anyway: an ISO date with the `T` spelled as a
        // space, which `ISO8601DateFormatter` refuses outright.
        "yyyy-MM-dd HH:mm:ss ZZZ",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss",
    ].map(makeFormatter)

    /// `en_US_POSIX` and an explicit GMT, both non-negotiable.
    ///
    /// The locale, because month and weekday names are matched as text: on a device set
    /// to Traditional Chinese a formatter using the current locale is looking for
    /// 「十月」 and will not recognise `Oct`, so every date in every feed would fail on
    /// exactly the devices this app is written for.
    ///
    /// The timezone, because it is what a pattern with no zone field falls back to, and
    /// the device's own zone is not an answer the publisher gave — the same feed would
    /// then hold different dates depending on where the reader is standing.
    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }
}
