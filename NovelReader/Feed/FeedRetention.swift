import Foundation

/// Which of a subscription's articles have outlived their welcome.
///
/// A feed is the one medium in this app that grows on its own. A novel is bounded by the
/// book; a subscription read for a year is thousands of articles nobody will open again,
/// and every one of them is text on disk. So this exists — and everything in it is written
/// around one fact: deleting a reader's archive is not undoable, and a purge that takes
/// something they wanted is worse than a purge that keeps too much.
///
/// Pure, and separate from the code that does the deleting, because the rules are the
/// substance here. Every protection below is one thing a naive "keep the newest ten" would
/// have destroyed.
enum FeedRetention {
    /// What the reader asked for, resolved from `FeedRetentionSettings`.
    struct Policy: Equatable {
        /// How many articles a subscription keeps. Zero means "keep everything", which is
        /// how the whole feature is turned off.
        var keepCount: Int
        /// How long an article that is over the limit is left alone before it goes. Not a
        /// stay of execution for its own sake: a reader who opens the app, sees forty
        /// unread, and reads six of them over the week should still find the other
        /// thirty-four where they left them.
        var grace: TimeInterval
        /// The same for an article that is over the limit *and* unread. Nil is "keep
        /// unread articles forever", which is the setting for someone who treats a
        /// subscription as an inbox.
        var unreadRetention: TimeInterval?

        static let off = Policy(keepCount: 0, grace: 0, unreadRetention: nil)
    }

    /// The articles that may be deleted now.
    ///
    /// - Parameters:
    ///   - chapters: the book's whole catalog, in reading order — oldest first, the order
    ///     `mergeCatalog` writes.
    ///   - lastReadIndex: where the reader is, as `Book.lastReadIndex(in:)` resolves it.
    ///     Nil means they have no place in this catalog, and then every article is unread.
    ///   - marked: article ids carrying a bookmark or a highlight.
    ///   - stillPublished: the oldest article the publisher's document still lists, from
    ///     `FeedFetchState.windowOldestAt`. Nothing at or after it is ever deleted — see
    ///     the resurrection note below — and while it is unknown nothing is deleted at
    ///     all: a feed whose host has gone is a feed whose articles exist nowhere else,
    ///     and it is the one that would otherwise be emptied a launch at a time.
    static func purgeable(
        from chapters: [Chapter],
        lastReadIndex: Int?,
        marked: Set<String>,
        stillPublished: Date?,
        policy: Policy,
        now: Date = Date()
    ) -> [Chapter] {
        guard policy.keepCount > 0, chapters.count > policy.keepCount,
              let stillPublished
        else { return [] }
        // The newest `keepCount`, whatever else is true of them. Reading order is
        // chronological, so this is the tail.
        let surplus = chapters.dropLast(policy.keepCount)

        return surplus.filter { chapter in
            // The reader is standing on it. Deleting it would leave the stored position
            // naming an article that no longer exists, which every count and every "next
            // chapter" resolves through — and the unread badge would jump from four to
            // four hundred.
            if let lastReadIndex, chapter.index == lastReadIndex { return false }
            // They marked it. A bookmark or a highlight is the one unambiguous statement
            // a reader makes about an article being worth keeping, and the marks would
            // cascade away with the row without a word.
            if marked.contains(chapter.siteChapterId) { return false }
            // The publisher still lists it. Deleting one of these would delete it, have
            // the next refresh fetch it straight back, and mark it unread again — for
            // ever, on every launch. A limit smaller than the feed's own window is
            // therefore honoured as "keep at least this many", not as a ceiling.
            if let publishedAt = chapter.publishedAt, publishedAt >= stillPublished {
                return false
            }
            // Old enough to be over the limit for a while, not merely over it today.
            guard let arrived = chapter.addedAt ?? chapter.publishedAt,
                  now.timeIntervalSince(arrived) >= policy.grace
            else { return false }
            // Unread articles keep their own, longer clock — the reader has not had their
            // turn with these yet.
            //
            // The article's own flag, which is what the shelf's count reads too. It used
            // to be "past the reading position", and that made this protection weaker than
            // it looked: an article the reader deliberately skipped past counted as read
            // and lost its longer clock, while one they had read and then scrolled back
            // from kept it.
            if chapter.isUnread {
                guard let unreadRetention = policy.unreadRetention,
                      now.timeIntervalSince(arrived) >= unreadRetention
                else { return false }
            }
            return true
        }
    }
}
