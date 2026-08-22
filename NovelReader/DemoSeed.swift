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

    /// Adds `stressBook` on top of the demo library: one book long enough, and fully
    /// on disk, to rebuild the state a reading session reaches after hours of
    /// continuous scrolling — which is where the "tap stalls for seconds" report
    /// lives. Separate from the screenshot fixtures because those are pixels in a
    /// store listing, and a fourth shelf row would change every one of them.
    nonisolated static let stressArgument = "-NovelReaderDemoStress"

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
        // Seeded after the screenshot books so its progress row is the newest one:
        // the reading history opens first and sorts by last-read time, which makes
        // this book the first row a stress walk taps.
        if ProcessInfo.processInfo.arguments.contains(stressArgument) {
            seed(stressBook, into: env)
        }
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
    ///
    /// Two of the three carry a reading position and one does not, which is what makes
    /// both of the screens that show progress worth shooting: the shelf gets a row of
    /// each kind, and the reading history gets a list rather than a single entry.
    private static let books = [
        DemoBook(siteId: "demo.example.com", bookId: "2087", title: "山海拾遺",
                 author: "陳知白", chapterCount: 210, downloaded: 6, readingChapter: 40),
        DemoBook(siteId: "demo.example.com", bookId: "1042", title: "星河渡口",
                 author: "沈聞舟", chapterCount: 128, downloaded: 12, readingChapter: 3),
        DemoBook(siteId: "books.example.org", bookId: "5513", title: "霧都舊事",
                 author: "林可昀", chapterCount: 64, downloaded: 0, readingChapter: nil),
    ]

    /// Every chapter on disk, so a scroll can cross a hundred and fifty seams without
    /// once touching the network — the report this serves says downloaded books stall
    /// too, so the network must not be able to explain anything the walk observes.
    private static let stressBook = DemoBook(
        siteId: "demo.example.com", bookId: "9001", title: "長夜行",
        author: "顧一葦", chapterCount: 160, downloaded: 160, readingChapter: 1
    )

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
            // The field is a place in reading order; the ids seeded above run from 1.
            let text = paragraphs(chapter: chapter + 1)
            // Part-way into the chapter, not at its head: the shelf and the reader both
            // say how far in the reader got, and a fixture parked at 0% would put that
            // in a store screenshot with nothing to show. The share is measured against
            // this same text, exactly the way the reader measures it, so the number on
            // the shelf and the one in the reader's capsule are the same number.
            let anchor = TextAnchor(paragraph: text.count / 2, characterOffset: 0)
            try? env.repo.updateProgress(
                bookId: book.id,
                position: ReadingPosition(siteChapterId: "\(chapter + 1)", anchor: anchor),
                fraction: anchor.fraction(in: text)
            )
        }
    }

    private static let chapterTitles = [
        "夜渡", "舊碼頭", "北風起", "第三封信", "無名的燈", "落雪之前",
        "渡口重逢", "舊約定", "回聲", "遠行",
    ]

    /// The text every demo chapter carries.
    ///
    /// Long enough to be **more than one page** in the paginated reader on any phone.
    /// That is a test requirement, not a taste for length: a one-page chapter cannot
    /// exercise a page turn at all, so the cross-page selection walk has nothing to
    /// walk — it caught exactly that and failed loudly rather than passing vacuously.
    /// Anyone trimming this should check `CrossPageSelectionGestureTests` first.
    private static func paragraphs(chapter: Int) -> [String] {
        [
            "渡口的燈亮到很晚。沈聞舟把外套的領子豎起來，站在木棧橋的盡頭，看著遠處那條船慢慢靠過來。",
            "水面上浮著一層薄薄的霧，燈光落進去，散成一片模糊的橘色。他數過了，這是今晚第七班船。",
            "「你還是來了。」身後有人說。",
            "他沒有回頭。這句話他在心裡練習過很多次，真的聽見的時候，反而想不起要怎麼回答。",
            "「我以為你不會等。」那個聲音又說，比剛才近了一些。",
            "「我也以為。」他終於開口，聲音被風吹得很散，「可是船還沒到。」",
            "候船室的窗玻璃上結了一層水氣，有人用指尖畫過，留下一道歪斜的痕跡，像誰寫了一半就改了主意。",
            "牆邊的長椅上坐著一個提著鐵桶的老人，桶裡的魚早就不動了，他卻還守著，彷彿在等一個不會來的買主。",
            "「這幾年你都在北邊？」她問。",
            "「在。」他說，「冬天很長，長到我開始記不清南邊的雨。」",
            "「那你還記得什麼？」",
            "他想了一會兒。他想說的是碼頭邊那家賣熱湯的鋪子、是六月裡曬得發白的石階、是她把傘往他這邊傾過來時肩上被淋濕的那一片。可他最後只說：「記得這裡的燈。」",
            "風從水面上壓過來，帶著鐵鏽和柴油的氣味。遠處的貨輪把一整排燈點亮，倒影在浪裡碎成一片一片。",
            "「你為什麼不寫信。」她的語氣不像問句。",
            "「寫了。」他說，「都沒有寄。」",
            "他沒有說那些信現在還壓在行李箱最底層，紙都軟了，字跡被潮氣泡得發灰。",
            "候船室的鐘停在十一點四十分，玻璃罩裡積了灰。沒有人去修它，久了大家便照著自己的手錶進出。",
            "遠處傳來汽笛聲，低沉、綿長，像是從很多年以前傳過來的。橋上的木板隨著水波輕輕晃了一下。",
            "他忽然想起許多年前也是這樣一個夜裡，她把船票塞進他手裡，說先走的人不許回頭。那時他信了。",
            "水鳥從桅杆上驚起，繞著燈飛了兩圈，又落回原處。棧橋盡頭的鐵欄杆被無數隻手摸得發亮。",
            "汽笛第二次響起的時候，棧橋上的人都站了起來。有人喊了一個名字，前面的隊伍動了一動，又停住。",
            "「等一下。」她忽然說。",
            "他停下來，看著她從口袋裡拿出一個信封，邊角磨得起了毛。「這個，」她說，「我也沒有寄。」",
            "兩個人站在原地，誰都沒有伸手去接。船身撞上輪胎做的緩衝墊，發出一聲鈍響。",
            "「我這次不走了。」他說。",
            "她沒有應聲，只是把信封收回口袋，動作很輕，像是怕弄壞裡面的東西。",
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
