import Foundation
import Observation

/// Which chapters of a comic are loaded, where the reader is in them, and when that is
/// written down.
///
/// `ReaderModel`'s counterpart, and much smaller — everything that one carries for
/// bookmarks, highlights, two renderers and a read-ahead of composed text has no
/// meaning here. What is kept is the part that is the same in every reader: a window of
/// loaded chapters that grows in the direction of travel, a position that names a
/// chapter by the site's own id, and `ProgressWriteRule` deciding when a position is
/// worth a row in the database.
@MainActor
@Observable
final class ComicReaderModel {
    /// One chapter's page addresses.
    ///
    /// The addresses only, and they are not written down anywhere. On these CDNs a page
    /// URL carries an expiry and a signature — see `BookService.chapterImageURLs` — so a
    /// list saved today is a column of 403s tomorrow. It lives exactly as long as the
    /// chapter is on screen.
    struct LoadedChapter: Identifiable {
        let chapter: Chapter
        let imageURLs: [URL]
        /// The page the images were listed on, sent as `Referer` for every one of them.
        let chapterPage: URL
        /// Where a page that came off the network is put so it need not be fetched twice.
        /// Two different places, decided when the chapter opens: the cache, for a chapter
        /// being read online, or the hole in a downloaded chapter that the page was
        /// fetched to fill. Absent when there is nowhere — a downloaded chapter with no
        /// gaps asks for nothing.
        let keepPage: ((Int, Data) -> Void)?
        /// Where a page already is, for a chapter being read online. The other half of
        /// `keepPage`, and absent for the same reasons: nothing was kept, or what was
        /// kept is the chapter itself.
        let cachedPage: ((Int) -> URL?)?
        /// The pages this chapter is short — the gaps in a download, whose slots hold a
        /// live address rather than the page itself. Named here so the store can offer
        /// them as retries instead of quietly fetching them; see `ComicPageStore.init`.
        let missingPages: Set<Int>
        var id: String { chapter.id }
    }

    /// Where the renderer must put the reader. Consumed once and cleared by it.
    struct ScrollTarget: Equatable {
        let chapterIndex: Int
        let page: Int
    }

    private(set) var chapters: [Chapter] = []
    private(set) var loaded: [LoadedChapter] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var currentChapterIndex = 0
    private(set) var currentPage = 0
    private(set) var scrollTarget: ScrollTarget?

    var hasMore: Bool {
        guard let last = loaded.last else { return false }
        return last.chapter.index < chapters.count - 1
    }

    var currentLoadedChapter: LoadedChapter? {
        loaded.first { $0.chapter.index == currentChapterIndex }
    }

    /// What sits under the last loaded chapter.
    var footerState: ReaderTextFooter.State {
        if isLoading { return .loading }
        return hasMore ? .none : .endOfBook
    }

    /// What would be stored for where the reader is now.
    ///
    /// The page goes in the anchor's paragraph slot and the character offset stays zero
    /// — a comic has nothing finer than a page to name. See `Book.lastReadParagraph`.
    var currentPosition: ReadingPosition? {
        guard chapters.indices.contains(currentChapterIndex) else { return nil }
        return ReadingPosition(
            siteChapterId: chapters[currentChapterIndex].siteChapterId,
            anchor: TextAnchor(paragraph: currentPage, characterOffset: 0)
        )
    }

    private let book: Book
    private let env: AppEnvironment
    private var writeRule = ProgressWriteRule()
    private var currentFraction: Double?
    /// Bumped by every jump, so a chapter fetched for a window the reader has left can
    /// tell that it belongs nowhere — `loaded` being empty cannot say it, since a jump
    /// empties it and then fills it.
    @ObservationIgnored private var generation = 0
    private var isTouching = false
    /// The chapter before the first one loaded, fetched and waiting for the reader's
    /// hand to come off the glass. Putting it in under a moving finger is the one thing
    /// the column stack cannot make invisible: the correction is exact, but the pan
    /// gesture computes its own destination from where the touch began.
    private var pendingPrevious: LoadedChapter?
    /// What the reader was asked to open with, so a retry has something to retry.
    private var openedAt: ReadingPosition?

    /// How many chapters stay in memory. Three, against the text reader's larger window,
    /// because a comic chapter is not paragraphs — it is 5–20MB of compressed pages, and
    /// an unbounded history is the fastest way to have iOS take the app away mid-read.
    private static let windowSize = 3

    init(book: Book, env: AppEnvironment) {
        self.book = book
        self.env = env
    }

    // MARK: - Loading

    func start(at position: ReadingPosition) async {
        openedAt = position
        chapters = (try? env.repo.chapters(bookId: book.id)) ?? []
        guard !chapters.isEmpty else {
            error = String(localized: "book.catalog.empty")
            return
        }
        // The one place a stored chapter id is resolved against reading order. A
        // position naming a chapter the site has dropped opens the book at its start:
        // the reader asked for this book, and its first chapter is the only place left
        // that still exists.
        let index = chapters.firstIndex { $0.siteChapterId == position.siteChapterId } ?? 0
        await jump(toChapterAt: index, page: position.anchor.paragraph)
    }

    /// Replaces what is on screen with a single chapter, landing on `page`.
    ///
    /// Addressed by reading order rather than by chapter id, like every other movement
    /// through the book: the catalog row, the two chapter buttons and the reader running
    /// off the end all mean "the next one", and the loaded array is the order they mean.
    func jump(toChapterAt index: Int, page: Int = 0) async {
        guard chapters.indices.contains(index) else { return }
        generation += 1
        let mine = generation
        loaded = []
        pendingPrevious = nil
        error = nil
        currentChapterIndex = index
        currentPage = page
        // Stated before the chapter can possibly have arrived. The renderer applies it
        // the moment a column with that index exists, which is where most landings
        // actually happen.
        scrollTarget = ScrollTarget(chapterIndex: index, page: page)
        guard let chapter = await fetch(chapters[index], generation: mine) else { return }
        guard mine == generation else { return }
        loaded = [chapter]
    }

    func loadNext() async {
        guard !isLoading, let last = loaded.last else { return }
        let next = last.chapter.index + 1
        guard chapters.indices.contains(next) else { return }
        let mine = generation
        guard let chapter = await fetch(chapters[next], generation: mine) else { return }
        guard mine == generation, loaded.last?.chapter.index == next - 1 else { return }
        loaded.append(chapter)
        trimBehind()
    }

    /// Fetches the chapter above the reader, and holds it until their hand is off the
    /// glass.
    ///
    /// The insert itself is exact — the coordinator shifts content and offset together —
    /// but `setContentOffset` during a drag fights the pan gesture, which has already
    /// computed where it is going. So the chapter waits, exactly as the text reader's
    /// does, and goes in the moment the touch ends.
    func loadPrevious() async {
        guard !isLoading, pendingPrevious == nil, let first = loaded.first else { return }
        let previous = first.chapter.index - 1
        guard chapters.indices.contains(previous) else { return }
        let mine = generation
        guard let chapter = await fetch(chapters[previous], generation: mine) else { return }
        guard mine == generation, loaded.first?.chapter.index == previous + 1 else { return }
        pendingPrevious = chapter
        showPreviousIfSettled()
    }

    private func showPreviousIfSettled() {
        guard !isTouching, let chapter = pendingPrevious,
              loaded.first?.chapter.index == chapter.chapter.index + 1 else { return }
        pendingPrevious = nil
        loaded.insert(chapter, at: 0)
        trimAhead()
    }

    /// Reads one chapter's image list, reporting anything that goes wrong.
    ///
    /// A challenge or a sign-in wall goes to the shell, which owns the one web view a
    /// sheet can show; everything else becomes the reader's own inline failure, which
    /// has a retry and a way out on it.
    private func fetch(_ chapter: Chapter, generation mine: Int) async -> LoadedChapter? {
        guard let page = URL(string: chapter.url) else {
            error = String(localized: "reader.error.badURL")
            return nil
        }
        isLoading = true
        defer { isLoading = false }
        // Local pages win, and are looked for before the site rule is: a downloaded
        // chapter must open with no network at all — the entire point of downloading it
        // — and that has to hold for a book whose rule this device never installed.
        // `ComicPageStore` reads whichever kind of address it is handed, so nothing
        // above this line knows which happened.
        let stored = await storedPages(of: chapter)
        guard mine == generation else { return nil }
        if !stored.isEmpty {
            return await opening(chapter, from: stored, page: page, generation: mine)
        }
        guard let rule = env.sites.rule(id: book.siteId) else {
            error = String(localized: "book.missingRule")
            return nil
        }
        do {
            let urls = try await env.bookService.chapterImageURLs(rule: rule, chapter: chapter)
            guard mine == generation else { return nil }
            // Every page read online is kept, and looked for before it is asked for
            // again. That is what makes scrolling back through a chapter — or opening it
            // again tomorrow — a disk read rather than fifty more requests, and what lets
            // the store hold only six pages' bytes in memory without the reader paying
            // for the seventh twice.
            let cache = env.cache
            let book = self.book
            let siteChapterId = chapter.siteChapterId
            #if DEBUG
            ComicProbe.opened(
                chapter: chapter.index, pages: urls.count, source: "web", missing: []
            )
            #endif
            return LoadedChapter(
                chapter: chapter, imageURLs: urls, chapterPage: page,
                keepPage: { index, bytes in
                    cache.store(bytes, page: index, of: book, siteChapterId: siteChapterId)
                },
                cachedPage: { index in
                    cache.page(index, of: book, siteChapterId: siteChapterId)
                },
                missingPages: []
            )
        } catch {
            guard mine == generation else { return nil }
            report(error)
            return nil
        }
    }

    /// A chapter that is on the device, with the pages it is short fetched from the site.
    ///
    /// A gap is a page the download could not get (`ChapterFileStore.writePages`), and
    /// it is written as an empty marker so that it keeps its number. Left alone it stays
    /// a gap for the life of the chapter: the reader's retry button would re-read the
    /// same empty file and fail the same way, because nothing on the device can fill it.
    ///
    /// So the addresses are asked for again — once, only for a chapter that has a gap,
    /// and only when there is a rule to ask with. The marker's slot is given the live
    /// address, and the page is handed to the store as one it already knows is missing:
    /// the reader sees its retry button straight away, and the address is what that button
    /// aims at. `keepPage` writes what comes back into the hole, so a gap the reader
    /// bothered to fill stays filled.
    ///
    /// Offered rather than fetched, because the alternative was measured and is worse. A
    /// gap fetched silently on open shows nothing at all while the request runs, and these
    /// CDNs stall rather than refuse — a whole `URLSession` timeout of black page with no
    /// button on it, which is the retry disappearing exactly when it is needed.
    ///
    /// Everything about this fails soft. No rule, no network, a list that no longer has
    /// the same number of pages in it — the chapter still opens, still reads, and still
    /// shows a retry button on the page it is short. A downloaded chapter must never
    /// need the network to be readable, and one page of it is not worth breaking that.
    private func opening(
        _ chapter: Chapter, from stored: [URL], page: URL, generation mine: Int
    ) async -> LoadedChapter? {
        let gaps = stored.indices.filter { ChapterFileStore.isGap(stored[$0]) }
        guard !gaps.isEmpty, let rule = env.sites.rule(id: book.siteId),
              let live = try? await env.bookService.chapterImageURLs(rule: rule, chapter: chapter),
              live.count == stored.count
        else {
            #if DEBUG
            ComicProbe.opened(
                chapter: chapter.index, pages: stored.count, source: "device", missing: gaps
            )
            #endif
            // No `missingPages`, and that is not an oversight: every slot here still holds
            // the marker file itself, which reads as a failure the instant it is opened.
            // Naming them would only replace one immediate button with another.
            return LoadedChapter(
                chapter: chapter, imageURLs: stored, chapterPage: page,
                keepPage: nil, cachedPage: nil, missingPages: []
            )
        }
        guard mine == generation else { return nil }
        var urls = stored
        for gap in gaps { urls[gap] = live[gap] }
        let siteChapterId = chapter.siteChapterId
        let downloads = env.downloads
        let book = self.book
        let fillable = Set(gaps)
        #if DEBUG
        ComicProbe.opened(
            chapter: chapter.index, pages: urls.count, source: "device+web", missing: gaps
        )
        #endif
        return LoadedChapter(
            chapter: chapter, imageURLs: urls, chapterPage: page,
            keepPage: { index, bytes in
                // Into the download, not the cache: this chapter is one the reader asked
                // to keep, and a page of it belongs where the rest of it is.
                guard fillable.contains(index) else { return }
                try? downloads.fillPage(
                    bytes, index: index, book: book, siteChapterId: siteChapterId
                )
            },
            // Nothing to look up. Every page of this chapter but the gaps is already a
            // file address, and a gap filled during this read is one page of fifty — not
            // worth a lookup on every page of every downloaded chapter to save.
            cachedPage: nil,
            // Offered rather than fetched. The addresses above are what a retry aims at,
            // not a second download starting behind the reader's back: a gap asked for
            // silently on open is a black page for as long as the site takes to answer,
            // and on a CDN that stalls that is a minute with nothing to tap.
            missingPages: fillable
        )
    }

    /// A downloaded chapter's pages, listed off the main actor.
    ///
    /// The listing is one directory read, but it lands in the middle of the scroll that
    /// asked for it — the reader is at the seam between two chapters when this runs —
    /// and a filesystem hit on the main thread there is a stutter they can see. Only the
    /// file store crosses over, which is a path and a `FileManager`; the database is not
    /// touched, because "is it downloaded" was answered by the row already in hand.
    /// `ReaderView.storedParagraphs` does the same for text.
    ///
    /// The flag is checked *and* the disk is looked at, and it is the disk that decides:
    /// a chapter whose files went missing — deleted from the storage screen while its
    /// row was being rewritten — reads as not downloaded and is fetched, rather than
    /// opening as a chapter of no pages.
    private func storedPages(of chapter: Chapter) async -> [URL] {
        guard chapter.isDownloaded else { return [] }
        let files = env.files
        let siteId = book.siteId
        let siteBookId = book.siteBookId
        let siteChapterId = chapter.siteChapterId
        return await Task.detached(priority: .userInitiated) {
            files.pageURLs(siteId: siteId, siteBookId: siteBookId, siteChapterId: siteChapterId)
        }.value
    }

    func retry() async {
        error = nil
        guard let position = openedAt ?? currentPosition else { return }
        await start(at: position)
    }

    /// Routes a failure the same way the rest of the app does.
    func report(_ error: any Error) {
        if WebFetcher.needsTheUser(error) {
            env.report(error)
            // Not also shown inline: the sheet the shell is about to present is the
            // thing to look at, and a red panel under it says the same failure twice.
            return
        }
        self.error = error.localizedDescription
    }

    /// Drops chapters the reader has left behind, keeping the window bounded.
    private func trimBehind() {
        guard loaded.count > Self.windowSize else { return }
        loaded.removeFirst(loaded.count - Self.windowSize)
    }

    private func trimAhead() {
        guard loaded.count > Self.windowSize else { return }
        loaded.removeLast(loaded.count - Self.windowSize)
    }

    /// Everything but the chapter on screen. What a memory warning asks for — the
    /// chapters either side can be fetched again, and the alternative is iOS taking the
    /// whole app away.
    func dropDistantChapters() {
        pendingPrevious = nil
        loaded = loaded.filter { $0.chapter.index == currentChapterIndex }
    }

    // MARK: - Position

    /// Called by the renderer whenever the window moves onto a different page.
    func record(_ place: ComicPlace) {
        currentChapterIndex = place.chapterIndex
        currentPage = place.page
        currentFraction = place.fraction
        write(occasion: .reading)
    }

    func clearScrollTarget() {
        scrollTarget = nil
    }

    func touch(down: Bool) {
        isTouching = down
        if !down { showPreviousIfSettled() }
    }

    /// A moment this position may be the last one anything is asked for.
    func persistProgress() {
        write(occasion: .leaving)
    }

    func stopReading() {
        persistProgress()
    }

    private func write(occasion: ProgressWriteRule.Occasion) {
        guard let position = currentPosition,
              writeRule.shouldWrite(position, occasion: occasion)
        else { return }
        env.recordProgress(
            book: book, position: position, fraction: currentFraction,
            // The shelf and the history are worth refreshing when the reader stops or
            // changes chapter, and not several times a minute behind a screen nobody is
            // looking at — the same split `ReaderModel.recordProgress` makes.
            publish: occasion == .leaving
        )
    }
}
