import XCTest
@testable import NovelReader

/// How a batch of addresses is scheduled, which is the part of adding books with a failure
/// mode of its own.
///
/// Driven through stub closures rather than an `AppEnvironment`, so what is being asserted
/// is the scheduling and nothing else — no database, no web view, no network. Every case
/// here is a way the obvious implementation ("await them in a loop", or "start them all")
/// either wastes the reader's afternoon or points four connections at one blog.
@MainActor
final class BookAdditionsTests: XCTestCase {
    /// What the stub was asked for, and how many of those asks overlapped.
    private final class Record {
        private(set) var started: [String] = []
        private(set) var inFlight = 0
        private(set) var peakInFlight = 0
        private(set) var peakPerHost = 0
        private var perHost: [String: Int] = [:]

        func begin(_ address: String) {
            started.append(address)
            inFlight += 1
            peakInFlight = max(peakInFlight, inFlight)
            let host = URL(string: address)?.host() ?? address
            perHost[host, default: 0] += 1
            peakPerHost = max(peakPerHost, perHost[host]!)
        }

        func end(_ address: String) {
            inFlight -= 1
            perHost[URL(string: address)?.host() ?? address, default: 1] -= 1
        }
    }

    private var record: Record!
    private var settled = 0

    override func setUp() {
        record = Record()
        settled = 0
    }

    /// A queue whose subscriptions each take `delay`, and whose books do nothing at all.
    private func makeQueue(
        delay: Duration = .milliseconds(60),
        failing: Set<String> = [],
        keeps: Bool = true
    ) -> BookAdditions {
        let queue = BookAdditions(pacer: RequestPacer(gap: 0...0))
        let record = record!
        queue.connect(
            BookAdditions.Work(
                subscribe: { address, _ in
                    record.begin(address)
                    defer { record.end(address) }
                    try await Task.sleep(for: delay)
                    if failing.contains(address) { throw FeedService.FeedError.http(500) }
                    return "Feed at \(address)"
                },
                addBook: { address in
                    record.begin(address)
                    defer { record.end(address) }
                    try await Task.sleep(for: delay)
                    if failing.contains(address) { throw FeedService.FeedError.badAddress }
                    return "Book at \(address)"
                },
                keep: { address, title in keeps ? (title ?? address) : nil },
                settled: { [weak self] in self?.settled += 1 },
                report: { _ in }
            )
        )
        return queue
    }

    private func lines(_ addresses: [String], titles: [String?]? = nil) -> [AddBookLine] {
        AddBookLine.numbered(
            addresses.enumerated().map { ($1, titles?[$0]) }
        )
    }

    // MARK: - Parallelism

    /// The feature the reader asked for. Twelve blogs are twelve unrelated servers, and
    /// reading them one at a time is eleven idle hosts and an afternoon of waiting.
    func testSubscriptionsOnDifferentHostsAreReadAtTheSameTime() async {
        let queue = makeQueue()
        let addresses = (0..<8).map { "https://site\($0).example/feed" }

        let started = ContinuousClock.now
        queue.start(lines(addresses), as: .subscription)
        await queue.settle()

        XCTAssertEqual(queue.added, 8)
        XCTAssertGreaterThan(record.peakInFlight, 1, "one at a time is the bug this fixes")
        XCTAssertLessThan(
            ContinuousClock.now - started, .milliseconds(60 * 8),
            "and the whole batch must come in under the cost of running it in turn"
        )
    }

    /// The cap, which is not politeness — it is the one web view. Every feed in flight
    /// also holds a place in the queue that turns markup into paragraphs, and a reader who
    /// opens a book mid-import waits behind however many are lined up there.
    func testNoMoreThanTheCapAreReadAtOnce() async {
        let queue = makeQueue()
        let addresses = (0..<12).map { "https://site\($0).example/feed" }

        queue.start(lines(addresses), as: .subscription)
        await queue.settle()

        XCTAssertLessThanOrEqual(record.peakInFlight, BookAdditions.maxConcurrentFeeds)
    }

    /// And the rule that makes the parallelism defensible. Four feeds from one blog is one
    /// server being asked for four things at once by a reader who did nothing but open the
    /// app — which is the shape that gets answered with a 429.
    func testTwoFeedsFromOneHostAreNeverReadAtOnce() async {
        let queue = makeQueue()
        let addresses = (0..<4).map { "https://one.example/feed/\($0)" }
            + (0..<4).map { "https://two.example/feed/\($0)" }

        queue.start(lines(addresses), as: .subscription)
        await queue.settle()

        XCTAssertEqual(queue.added, 8)
        XCTAssertEqual(record.peakPerHost, 1)
    }

    /// Novels and comics are the medium that cannot do this: the fetcher is one web view
    /// driving one page at a time, so ten parallel calls would queue behind each other
    /// anyway — having first told the reader all ten were in flight.
    func testBooksAreStillAddedOneAtATime() async {
        let queue = makeQueue()

        queue.start(lines((0..<4).map { "https://site\($0).example/book/1" }), as: .book)
        await queue.settle()

        XCTAssertEqual(record.peakInFlight, 1)
    }

    // MARK: - Outliving the sheet

    /// The reason any of this moved out of the sheet. A run has to be startable and then
    /// left alone; nothing that watches it is required for it to finish.
    func testARunFinishesWithNobodyAwaitingIt() async {
        let queue = makeQueue(delay: .milliseconds(20))
        queue.start(lines(["https://a.example/feed"]), as: .subscription)
        XCTAssertTrue(queue.isRunning)

        await queue.settle()

        XCTAssertFalse(queue.isRunning)
        XCTAssertEqual(queue.added, 1)
        XCTAssertEqual(settled, 1, "and the library is told once, however the run ended")
    }

    /// A second batch started over a running one would be two sets of requests racing for
    /// the same hosts, reported in one place. The file picker and the sheet are two ways
    /// in, so this is refused here rather than prevented twice in the views.
    func testASecondRunIsRefusedWhileOneIsGoing() async {
        let queue = makeQueue()
        queue.start(lines(["https://a.example/feed"]), as: .subscription)

        XCTAssertFalse(queue.start(lines(["https://b.example/feed"]), as: .subscription))

        await queue.settle()
        XCTAssertEqual(record.started, ["https://a.example/feed"])
    }

    /// Stopping means "add no more", not "undo what you added". What was never started
    /// stays untouched, which is what the report has to be able to show.
    func testStoppingLeavesTheUntriedRowsAlone() async {
        let queue = makeQueue(delay: .milliseconds(200))
        let addresses = (0..<12).map { "https://site\($0).example/feed" }
        queue.start(lines(addresses), as: .subscription)

        try? await Task.sleep(for: .milliseconds(40))
        queue.stop()
        await queue.settle()

        XCTAssertFalse(queue.isRunning)
        XCTAssertLessThan(record.started.count, addresses.count)
        XCTAssertEqual(
            queue.lines.filter { $0.status.isFinished }.count + queue.lines.filter {
                if case .waiting = $0.status { return true } else { return false }
            }.count,
            addresses.count,
            "every row is either done or untouched — none is left claiming to be working"
        )
    }

    // MARK: - Failures

    /// One dead address out of twenty must not cost the reader the other nineteen. This is
    /// what a list pasted out of somebody else's reader looks like.
    func testOneDeadSubscriptionDoesNotStopTheRest() async {
        let queue = makeQueue(failing: ["https://b.example/feed"], keeps: false)

        queue.start(
            lines(["https://a.example/feed", "https://b.example/feed", "https://c.example/feed"]),
            as: .subscription
        )
        await queue.settle()

        XCTAssertEqual(queue.added, 2)
        XCTAssertEqual(queue.failures, 1)
    }

    /// The one thing an imported list does differently: a feed that will not answer is
    /// still kept, under the name the file gave it. The file is the evidence that the
    /// reader did subscribe to it, and a bad minute on a train is a poor reason to drop it
    /// silently from something they may delete afterwards.
    func testAnUnreachableFeedFromAListIsKeptUnderTheNameTheFileGaveIt() async {
        let queue = makeQueue(failing: ["https://b.example/feed"])

        queue.start(
            lines(
                ["https://a.example/feed", "https://b.example/feed"],
                titles: [nil, "Second Blog"]
            ),
            as: .subscriptionList
        )
        await queue.settle()

        XCTAssertEqual(queue.failures, 0)
        XCTAssertEqual(queue.lines.last?.status.note, "Second Blog")
    }

    /// And a pasted address gets no such treatment. Nobody vouched for it but the person
    /// who typed it a second ago, and a row on the shelf that opens onto nothing would be
    /// a worse answer than saying it did not work.
    func testAPastedAddressThatWillNotAnswerIsReportedNotKept() async {
        let queue = makeQueue(failing: ["https://b.example/feed"])

        queue.start(lines(["https://b.example/feed"]), as: .subscription)
        await queue.settle()

        XCTAssertEqual(queue.failures, 1)
    }
}
