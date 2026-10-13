package com.zeyanlin.novelreader.services

import com.zeyanlin.novelreader.data.Chapter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.OffsetDateTime

/**
 * The iOS `FeedParserTests`. A feed is the one source nobody wrote a rule for, so the parser is
 * all the site knowledge there is. Two answers matter far beyond parsing: an item's identity is
 * its `siteChapterId`, which position, bookmarks and highlights all point at; and the body,
 * which RSS wraps in CDATA — miss that and every article in the world is empty.
 */
class FeedParserTest {
    private val feedURL = "https://example.com/blog/feed.xml"

    private fun parse(text: String) = FeedParser.parse(text.toByteArray(), feedURL)

    private fun date(iso: String) = OffsetDateTime.parse(iso).toInstant().toEpochMilli()

    @Test
    fun rssReadsTheChannelAndItsItems() {
        val feed = parse(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/">
              <channel>
                <title>Example Blog</title>
                <link>https://example.com/</link>
                <image><url>https://example.com/icon.png</url></image>
                <item>
                  <title>First post</title>
                  <link>https://example.com/first</link>
                  <guid isPermaLink="false">tag:example.com,2026:1</guid>
                  <description>A teaser sentence.</description>
                  <pubDate>Wed, 02 Oct 2002 08:00:00 GMT</pubDate>
                  <dc:creator>Ada</dc:creator>
                </item>
              </channel>
            </rss>
            """.trimIndent(),
        )
        assertEquals("Example Blog", feed.title)
        assertEquals("https://example.com/", feed.homePageURL)
        assertEquals("https://example.com/icon.png", feed.iconURL)
        assertEquals(
            ParsedItem("tag:example.com,2026:1", "https://example.com/first", "First post", "A teaser sentence.", date("2002-10-02T08:00:00Z"), "Ada"),
            feed.items.single(),
        )
    }

    @Test
    fun anArticleWrappedInCdataSurvives() {
        val feed = parse("<rss version=\"2.0\"><channel><item><title>Post</title><description><![CDATA[<p>Real markup &amp; a paragraph.</p>]]></description></item></channel></rss>")
        assertEquals("<p>Real markup &amp; a paragraph.</p>", feed.items.first().contentHTML)
    }

    // Read the wrong way round, every article in the library ends at "read more".
    @Test
    fun theFullArticleWinsOverTheSummary() {
        val feed = parse(
            """<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><item>
              <description>Teaser.</description>
              <content:encoded><![CDATA[<p>The whole article.</p>]]></content:encoded>
            </item></channel></rss>""",
        )
        assertEquals("<p>The whole article.</p>", feed.items.first().contentHTML)
    }

    // `rel="self"` is the XML itself: "open the original" would hand it back.
    @Test
    fun theFeedsOwnAddressIsNotMistakenForTheSite() {
        val feed = parse(
            """<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom"><channel>
              <atom:link href="https://example.com/blog/feed.xml" rel="self" type="application/rss+xml"/>
              <link>https://example.com/blog/</link><title>Blog</title>
            </channel></rss>""",
        )
        assertEquals("https://example.com/blog/", feed.homePageURL)
    }

    @Test
    fun aChannelIsNotNamedAfterItsFirstArticle() {
        assertEquals("The blog", parse("<rss version=\"2.0\"><channel><item><title>An article</title></item><title>The blog</title></channel></rss>").title)
    }

    @Test
    fun relativeLinksAreResolvedAgainstTheFeed() {
        assertEquals("https://example.com/2026/09/a-post", parse("<rss version=\"2.0\"><channel><item><link>/2026/09/a-post</link></item></channel></rss>").items.first().url)
    }

    @Test
    fun rdfItemsSitBesideTheChannel() {
        val feed = parse(
            """<?xml version="1.0"?>
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:dc="http://purl.org/dc/elements/1.1/">
              <channel rdf:about="https://example.com/"><title>Old School</title><link>https://example.com/</link></channel>
              <item rdf:about="https://example.com/one"><title>One</title><link>https://example.com/one</link><dc:date>2002-10-02T08:00:00Z</dc:date></item>
            </rdf:RDF>""",
        )
        assertEquals("Old School", feed.title)
        assertEquals("One", feed.items.single().title)
        assertEquals(date("2002-10-02T08:00:00Z"), feed.items.single().datePublished)
    }

    @Test
    fun atomReadsEntriesAndTheirAlternateLinks() {
        val feed = parse(
            """<?xml version="1.0" encoding="utf-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <title>Atom Blog</title>
              <link rel="self" href="https://example.com/blog/feed.xml"/>
              <link rel="alternate" href="https://example.com/blog/"/>
              <icon>https://example.com/icon.png</icon>
              <entry>
                <title>An entry</title>
                <link rel="alternate" href="https://example.com/entry"/>
                <id>urn:uuid:1225c695</id>
                <published>2002-10-02T08:00:00Z</published>
                <updated>2026-09-03T00:00:00Z</updated>
                <author><name>Grace</name></author>
                <content type="html">&lt;p&gt;Escaped markup.&lt;/p&gt;</content>
              </entry>
            </feed>""",
        )
        assertEquals("Atom Blog", feed.title)
        assertEquals("https://example.com/blog/", feed.homePageURL)
        assertEquals("https://example.com/icon.png", feed.iconURL)
        val entry = feed.items.single()
        assertEquals("https://example.com/entry", entry.url)
        assertEquals("urn:uuid:1225c695", entry.guid)
        assertEquals("Grace", entry.author)
        assertEquals("<p>Escaped markup.</p>", entry.contentHTML)
        // When it appeared, not when it was last touched: `updated` is years later on purpose.
        assertEquals(date("2002-10-02T08:00:00Z"), entry.datePublished)
    }

    // Read as text, an xhtml article arrives as one paragraph-less run of prose.
    @Test
    fun atomXhtmlContentKeepsItsParagraphs() {
        val html = parse(
            """<feed xmlns="http://www.w3.org/2005/Atom"><entry><content type="xhtml">
              <div xmlns="http://www.w3.org/1999/xhtml"><p>First paragraph.</p><p>Second one, with <em>emphasis</em>.</p></div>
            </content></entry></feed>""",
        ).items.single().contentHTML!!
        assertTrue(html, "<p>First paragraph.</p>" in html)
        assertTrue(html, "<em>emphasis</em>" in html)
    }

    @Test
    fun atomFallsBackToTheSummaryAndToUpdated() {
        val item = parse("<feed xmlns=\"http://www.w3.org/2005/Atom\"><entry><summary>All there is.</summary><updated>2002-10-02T08:00:00Z</updated></entry></feed>").items.single()
        assertEquals("All there is.", item.contentHTML)
        assertEquals(date("2002-10-02T08:00:00Z"), item.datePublished)
    }

    @Test
    fun jsonFeedReadsItsItems() {
        val feed = parse(
            """
            {
              "version": "https://jsonfeed.org/version/1.1",
              "title": "JSON Blog",
              "home_page_url": "https://example.com/",
              "icon": "https://example.com/icon.png",
              "items": [{ "id": "1", "url": "https://example.com/one", "title": "One", "content_html": "<p>Markup.</p>",
                          "date_published": "2002-10-02T08:00:00Z", "authors": [{ "name": "Linus" }] }]
            }
            """.trimIndent(),
        )
        assertEquals("JSON Blog", feed.title)
        assertEquals("https://example.com/icon.png", feed.iconURL)
        assertEquals(ParsedItem("1", "https://example.com/one", "One", "<p>Markup.</p>", date("2002-10-02T08:00:00Z"), "Linus"), feed.items.single())
    }

    @Test
    fun plainTextContentBecomesParagraphs() {
        val feed = parse("""{ "version": "https://jsonfeed.org/version/1.1", "items": [{ "id": "1", "content_text": "Line one.\nLine <two>." }] }""")
        assertEquals("<p>Line one.</p><p>Line &lt;two&gt;.</p>", feed.items.single().contentHTML)
    }

    // A host's JSON error page would otherwise subscribe the reader to nothing and report success.
    @Test
    fun whatIsNotAFeedIsRefused() {
        assertThrows(FeedParser.NotAFeed::class.java) { parse("""{ "error": "not found", "items": [] }""") }
        assertThrows(FeedParser.NotAFeed::class.java) { parse("<!DOCTYPE html><html><body><h1>Hi</h1></body></html>") }
    }

    // One em dash in one headline must not cost the feed, and an unknown entity costs one word.
    @Test
    fun htmlEntitiesDoNotLoseTheFeed() {
        val feed = parse("<rss version=\"2.0\"><channel><title>Tips &amp; Tricks &mdash; the blog</title><item><title>Space&nbsp;bar</title></item><item><title>Say &frobnicate; now</title></item></channel></rss>")
        assertEquals("Tips & Tricks — the blog", feed.title)
        assertEquals(listOf("Space\u00A0bar", "Say &frobnicate; now"), feed.items.map { it.title })
    }

    @Test
    fun identityPrefersThePublishersIdThenThePermalink() {
        assertEquals("tag:a", ParsedItem(guid = "tag:a", url = "https://example.com/a", title = "A").identity)
        assertEquals("https://example.com/a", ParsedItem(url = "https://example.com/a", title = "A").identity)
    }

    // A recurring column shares its title, a batch shares its date; and a typo fixed is not a new article.
    @Test
    fun aHashedIdentitySeparatesArticlesButNotTheirCorrections() {
        val at = date("2002-10-02T08:00:00Z")
        assertNotEquals(ParsedItem(title = "Weekly digest", datePublished = at).identity, ParsedItem(title = "Weekly digest", datePublished = at + 60_000).identity)
        assertEquals(
            ParsedItem(title = "A post", contentHTML = "<p>teh</p>", datePublished = at).identity,
            ParsedItem(title = "A post", contentHTML = "<p>the</p>", datePublished = at).identity,
        )
        // The bytes iOS hashes, so a backup's marks find the same article on either platform.
        assertEquals(
            "sha256-" + java.security.MessageDigest.getInstance("SHA-256").digest("A post|2002-10-02 08:00:00 +0000".toByteArray())
                .take(12).joinToString("") { "%02x".format(it) },
            ParsedItem(title = "A post", datePublished = at).identity,
        )
    }

    @Test
    fun rfc822DatesAreReadInTheirCommonShapes() {
        val expected = date("2002-10-02T08:00:00Z")
        for (text in listOf("Wed, 02 Oct 2002 08:00:00 GMT", "Wed, 2 Oct 2002 08:00:00 +0000", "02 Oct 2002 08:00:00 GMT", "Wed, 02 Oct 2002 08:00 GMT", "Wed, 02 Oct 2002 08:00:00")) {
            assertEquals(text, expected, FeedDate.parse(text))
        }
    }

    // `2002-10-02 08:00:00` is also the prefix trap: a date-only reader tried early answers midnight.
    @Test
    fun isoDatesAreReadWithAndWithoutFractionsAndTheT() {
        val expected = date("2002-10-02T08:00:00Z")
        for (text in listOf("2002-10-02T08:00:00Z", "2002-10-02T08:00:00.000Z", "2002-10-02T16:00:00+08:00", "2002-10-02 08:00:00")) {
            assertEquals(text, expected, FeedDate.parse(text))
        }
        assertEquals(date("2002-10-02T00:00:00Z"), FeedDate.parse("2002-10-02"))
    }

    // "Now" would sort it to the top on every refresh.
    @Test
    fun anUnreadableDateIsNullRatherThanNow() {
        assertNull(FeedDate.parse("sometime last week"))
        assertNull(FeedDate.parse(""))
        assertNull(FeedDate.parse(null))
    }
}

/** The iOS `OPMLTests`: the promise that a reader's forty feeds are theirs and not this app's. */
class OPMLTest {
    private fun read(opml: String) = OPML.subscriptions(opml.toByteArray())

    @Test
    fun anExportedListIsReadFoldersAndAll() {
        val found = read(
            """<?xml version="1.0" encoding="UTF-8"?>
            <opml version="1.0"><head><title>Subscriptions</title></head><body>
              <outline text="Daring Fireball" title="Daring Fireball" type="rss" xmlUrl="https://daringfireball.net/feeds/main" htmlUrl="https://daringfireball.net/"/>
              <outline text="Tech">
                <outline text="Nested" xmlUrl="https://b.example/feed"/>
                <outline text="Deeper"><outline text="Deepest" xmlurl="https://c.example/feed"/></outline>
              </outline>
              <outline text="A note" _note="remember this"/>
              <outline text="Daily"><outline text="Again" xmlUrl="https://b.example/feed"/></outline>
            </body></opml>""",
        )
        assertEquals(
            listOf(
                OPML.Subscription("Daring Fireball", "https://daringfireball.net/feeds/main"),
                OPML.Subscription("Nested", "https://b.example/feed"),
                OPML.Subscription("Deepest", "https://c.example/feed"),
            ),
            found,
        )
    }

    @Test
    fun somethingThatIsNotOpmlReadsAsNoSubscriptions() {
        assertTrue(read("<html><body>Not OPML at all</body></html>").isEmpty())
        assertTrue(read("").isEmpty())
    }

    // An ampersand in a title is the commonest thing in the world, and raw it costs the whole export.
    @Test
    fun whatIsWrittenCanBeReadBackEscapedAndNamed() {
        val subscriptions = listOf(
            OPML.Subscription("Arts & \"Letters\"", "https://a.example/?feed=rss&x=1"),
            OPML.Subscription("Inessential", "https://inessential.com/feed.json"),
        )
        val document = OPML.document("Subscriptions", subscriptions)
        assertTrue(document, "Arts &amp;" in document)
        assertEquals(subscriptions, read(document))
        assertEquals("https://a.example/feed", read(OPML.document("S", listOf(OPML.Subscription(null, "https://a.example/feed")))).single().title)
    }
}

/** The iOS `FeedDiscoveryTests`: what someone pastes is the site, and its feed is a line in the head. */
class FeedDiscoveryTest {
    private fun discover(links: String, page: String = "https://example.com/blog/") =
        FeedDiscovery.feedURLs("<!DOCTYPE html><html><head><title>A blog</title>$links</head><body></body></html>".toByteArray(), page)

    @Test
    fun theDeclaredFeedIsFoundWhereverItsAddressIsRelativeTo() {
        assertEquals(listOf("https://example.com/feed.xml"), discover("""<link rel="alternate" type="application/rss+xml" href="https://example.com/feed.xml">"""))
        assertEquals(listOf("https://example.com/feed.xml"), discover("""<link rel="alternate" type="application/atom+xml" href="/feed.xml">"""))
        assertEquals(listOf("https://example.com/blog/atom.xml"), discover("""<link rel="alternate" type="application/atom+xml" href="atom.xml">"""))
    }

    @Test
    fun attributeStyleAndEscapingDoNotMatter() {
        assertEquals(
            listOf("https://example.com/a.xml", "https://example.com/b.xml", "https://example.com/?feed=rss&lang=en"),
            discover(
                """<LINK TYPE='application/rss+xml' REL='alternate' TITLE='Posts' HREF='/a.xml' />
                <link href=/b.xml rel=alternate type=application/atom+xml>
                <link rel="alternate" type="application/rss+xml" href="/?feed=rss&amp;lang=en">""",
            ),
        )
    }

    @Test
    fun alternatesThatAreNotFeedsAndTheBodyAreIgnored() {
        assertTrue(
            discover(
                """<link rel="alternate" hreflang="fr" href="https://example.com/fr/">
                <link rel="alternate" type="text/html" href="https://m.example.com/">
                <link rel="stylesheet" href="/style.css">
                <link rel="alternate" type="application/json" href="/api/posts.json">""",
            ).isEmpty(),
        )
        val html = """<html><head><title>A blog</title></head><body><link rel="alternate" type="application/rss+xml" href="/also-wrong.xml"></body></html>"""
        assertTrue(FeedDiscovery.feedURLs(html.toByteArray(), "https://example.com/").isEmpty())
    }

    // The comments feed is ranked last, not dropped: a site may publish nothing else. One feed declared twice is one.
    @Test
    fun aPostsFeedWinsOverCommentsAndRepeatsCollapse() {
        assertEquals(
            listOf("https://example.com/feed/", "https://example.com/comments/feed/"),
            discover(
                """<link rel="alternate" type="application/rss+xml" title="Comments Feed" href="https://example.com/comments/feed/">
                <link rel="alternate" type="application/rss+xml" title="Feed" href="https://example.com/feed/">
                <link rel="alternate" type="application/rss+xml" href="/feed/">""",
            ),
        )
    }

    @Test
    fun aPageThatIsNotUtf8StillGivesUpItsFeed() {
        val bytes = "<html><head><title>".toByteArray() + byteArrayOf(0xB8.toByte(), 0xEA.toByte(), 0xB4.toByte(), 0xC1.toByte()) +
            """</title><link rel="alternate" type="application/rss+xml" href="/feed.xml"></head>""".toByteArray()
        assertEquals(listOf("https://example.com/feed.xml"), FeedDiscovery.feedURLs(bytes, "https://example.com/blog/"))
    }
}

/**
 * The iOS `FeedRetentionTests`. Every case is a way "keep the newest ten" destroys something the
 * reader would not get back: their place, an article they marked, or one that comes straight
 * back announced as new for ever.
 */
class FeedRetentionTest {
    private val day = 24 * 60 * 60 * 1000L
    private val now = 1_800_000_000_000L

    private fun policy(keep: Int = 3, graceDays: Long = 7, unreadDays: Long? = 30) = FeedRetention.Policy(keep, graceDays * day, unreadDays?.let { it * day })

    /** Oldest first, a day apart; [readThrough] is what was read, stated apart from where the reader stands. */
    private fun articles(count: Int, oldestDaysAgo: Long = 400, readThrough: Int? = null) = (0 until count).map { i ->
        val at = now - (oldestDaysAgo - i) * day
        Chapter("feed|1|$i", "feed|1", "$i", i, "Article $i", "https://example.com/$i", at, at, publishedAt = at, readAt = if (readThrough != null && i <= readThrough) now else null)
    }

    private fun purgeable(chapters: List<Chapter>, lastReadIndex: Int? = null, marked: Set<String> = emptySet(), stillPublished: Long? = now, policy: FeedRetention.Policy = policy()) =
        FeedRetention.purgeable(chapters, lastReadIndex, marked, stillPublished, policy, now).map { it.siteChapterId }

    @Test
    fun onlyArticlesPastTheLimitGoAndOffMeansNothing() {
        assertEquals(listOf("0", "1", "2"), purgeable(articles(6, readThrough = 5), 5))
        assertTrue(purgeable(articles(3, readThrough = 2), 2).isEmpty())
        assertTrue(purgeable(articles(500, readThrough = 499), 499, policy = policy(keep = 0)).isEmpty())
    }

    @Test
    fun anArticleOverTheLimitWaitsOutTheGracePeriod() {
        val recent = articles(6, oldestDaysAgo = 3, readThrough = 5)
        assertTrue(purgeable(recent, 5).isEmpty())
        assertEquals(listOf("0", "1", "2"), purgeable(recent, 5, policy = policy(graceDays = 1)))
    }

    @Test
    fun unreadArticlesKeepTheirOwnLongerClock() {
        val catalog = articles(6, oldestDaysAgo = 45, readThrough = 1)
        assertEquals(listOf("0"), purgeable(catalog, 1, policy = policy(unreadDays = 90)))
        assertEquals(listOf("0", "2"), purgeable(catalog, 1, policy = policy(unreadDays = 30)))
        // Skipped past is not read: standing on the newest does not make the rest read.
        assertTrue(purgeable(articles(6, oldestDaysAgo = 45), 5, policy = policy(unreadDays = 90)).isEmpty())
        assertTrue(purgeable(articles(60), null, policy = policy(unreadDays = null)).isEmpty())
    }

    @Test
    fun whereTheReaderStandsWhatTheyMarkedAndWhatIsStillPublishedStay() {
        assertEquals(listOf("0", "2"), purgeable(articles(6, readThrough = 1), 1))
        assertEquals(listOf("0", "2"), purgeable(articles(6, readThrough = 5), 5, marked = setOf("1")))
        val catalog = articles(6, readThrough = 5)
        assertEquals(listOf("0"), purgeable(catalog, 5, stillPublished = catalog[1].publishedAt))
        // A feed never parsed here has no window to compare against: nothing goes.
        assertTrue(purgeable(articles(60, readThrough = 59), 59, stillPublished = null).isEmpty())
    }
}
