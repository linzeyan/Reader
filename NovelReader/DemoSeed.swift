#if DEBUG
import Foundation

/// Replaces the store with a small fictional library, for App Store screenshots.
///
/// Screenshots have to show a populated app, but they must not show the real
/// sites a user might add: the whole premise of this app (App Review 5.2) is
/// that it points at no particular content source, and a store listing naming
/// one would say the opposite. So the demo sources are `example.com` hosts and
/// the books are invented — the UI is the real UI, only the contents are props.
///
/// `#if DEBUG` plus a launch argument: this code is not in a Release binary at
/// all, and a Debug build still behaves normally unless asked.
@MainActor
enum DemoSeed {
    nonisolated static let launchArgument = "-NovelReaderDemoSeed"

    nonisolated static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static func applyIfRequested(to env: AppEnvironment) {
        guard isRequested else { return }
        apply(to: env)
    }

    private static func apply(to env: AppEnvironment) {
        // Start from empty every launch: a screenshot run must produce the same
        // pixels twice, and the Debug build has already seeded the recon rules.
        for rule in env.sites.rules { try? env.sites.remove(id: rule.id) }
        try? env.downloads.delete(.everything)
        for book in (try? env.repo.allBooks()) ?? [] { try? env.repo.removeBookmark(bookId: book.id) }

        for source in sources { _ = try? env.sites.importRule(data: source.ruleJSON) }
        for book in books { seed(book, into: env) }
        env.reloadLibrary()
    }

    // MARK: - Fixtures

    private struct Source {
        let id: String
        let name: String
        var ruleJSON: Data { Data(DemoSeed.ruleJSON(id: id, name: name).utf8) }
    }

    private struct DemoBook {
        let siteId: String
        let bookId: String
        let title: String
        let author: String
        let chapterCount: Int
        /// How many chapters have local text, so the download UI has something
        /// to show and the storage screen reports a real size.
        let downloaded: Int
        let readingChapter: Int?
    }

    private static let sources = [
        Source(id: "demo.example.com", name: "示範書城"),
        Source(id: "books.example.org", name: "範例文庫"),
    ]

    /// Seeded in this order; the library sorts newest-first, so the last one
    /// listed here is the one a screenshot walk opens.
    private static let books = [
        DemoBook(siteId: "demo.example.com", bookId: "2087", title: "山海拾遺",
                 author: "陳知白", chapterCount: 210, downloaded: 6, readingChapter: nil),
        DemoBook(siteId: "demo.example.com", bookId: "1042", title: "星河渡口",
                 author: "沈聞舟", chapterCount: 128, downloaded: 12, readingChapter: 3),
        DemoBook(siteId: "books.example.org", bookId: "5513", title: "霧都舊事",
                 author: "林可昀", chapterCount: 64, downloaded: 0, readingChapter: nil),
    ]

    private static func seed(_ demo: DemoBook, into env: AppEnvironment) {
        guard let book = try? env.repo.bookmark(
            siteId: demo.siteId, siteBookId: demo.bookId,
            title: demo.title, author: demo.author
        ) else { return }

        let entries = (1...demo.chapterCount).map { index in
            (siteChapterId: "\(index)",
             title: "第\(index)章　\(chapterTitles[(index - 1) % chapterTitles.count])",
             url: "https://\(demo.siteId)/book/\(demo.bookId)/\(index)")
        }
        try? env.repo.replaceCatalog(bookId: book.id, entries: entries)

        for index in 0..<demo.downloaded {
            try? env.downloads.save(
                paragraphs: paragraphs(chapter: index + 1),
                book: book,
                siteChapterId: "\(index + 1)"
            )
        }
        if let chapter = demo.readingChapter {
            try? env.repo.updateProgress(bookId: book.id, position: .chapterStart(chapter))
        }
    }

    private static let chapterTitles = [
        "夜渡", "舊碼頭", "北風起", "第三封信", "無名的燈", "落雪之前",
        "渡口重逢", "舊約定", "回聲", "遠行",
    ]

    private static func paragraphs(chapter: Int) -> [String] {
        [
            "渡口的燈亮到很晚。沈聞舟把外套的領子豎起來，站在木棧橋的盡頭，看著遠處那條船慢慢靠過來。",
            "水面上浮著一層薄薄的霧，燈光落進去，散成一片模糊的橘色。他數過了，這是今晚第七班船。",
            "「你還是來了。」身後有人說。",
            "他沒有回頭。這句話他在心裡練習過很多次，真的聽見的時候，反而想不起要怎麼回答。",
            "「我以為你不會等。」那個聲音又說，比剛才近了一些。",
            "「我也以為。」他終於開口，聲音被風吹得很散，「可是船還沒到。」",
            "遠處傳來汽笛聲，低沉、綿長，像是從很多年以前傳過來的。橋上的木板隨著水波輕輕晃了一下。",
            "第\(chapter)班船靠岸的時候，霧已經散了大半。他看清了甲板上站著的人，忽然覺得這一路的等待都有了去處。",
            "「走吧。」他說。",
            "兩個人的影子被燈拉得很長，一直延伸到棧橋的另一端，然後消失在夜色裡。",
        ]
    }

    /// A minimally complete rule: enough for the source list, the book screen and
    /// the reader to render. Nothing here ever hits the network in a demo run —
    /// every chapter these books point at is already on disk.
    private nonisolated static func ruleJSON(id: String, name: String) -> String {
        """
        {
          "id": "\(id)",
          "name": "\(name)",
          "host": "\(id)",
          "urls": {
            "book": "https://\(id)/book/{bookId}",
            "catalog": "https://\(id)/book/{bookId}/",
            "chapter": "https://\(id)/book/{bookId}/{chapterId}"
          },
          "idPatterns": {
            "bookId": "/book/([0-9]+)",
            "chapterId": "/book/[0-9]+/([0-9]+)"
          },
          "search": {
            "method": "GET",
            "url": "https://\(id)/search?q={query}",
            "queryField": "q",
            "resultLinkSelector": "a"
          },
          "book": { "title": { "selector": "h1" } },
          "catalog": { "container": "#catalog", "linkSelector": "a", "order": "ascending" },
          "chapter": {
            "titleSelectors": ["h1"],
            "contentSelectors": ["#content"],
            "stripSelectors": ["script"]
          },
          "notes": ["Fictional source used for App Store screenshots."]
        }
        """
    }
}
#endif
