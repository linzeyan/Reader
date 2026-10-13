package com.zeyanlin.novelreader

import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import com.zeyanlin.novelreader.network.WebFetcher
import com.zeyanlin.novelreader.services.BookService
import com.zeyanlin.novelreader.services.RuleDeriver
import com.zeyanlin.novelreader.siterules.SiteRule
import com.zeyanlin.novelreader.siterules.URLPatternInference
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import org.json.JSONObject
import java.io.File

/**
 * Runs the rule engine against live pages whose results the iOS notes recorded
 * (each docs/sites/<site>.json), so "Android reads a site the way iOS does" is a number, not a hope.
 * Debug builds only.
 *
 *     adb push <dev_docs>/novel_reader/sites /data/local/tmp/
 *     adb shell run-as com.zeyanlin.novelreader sh -c 'mkdir -p files && cp -r /data/local/tmp/sites files/'
 *     adb shell am start -n com.zeyanlin.novelreader/.ProbeActivity
 *     adb logcat -s Probe
 *
 * `--es mode derive` instead derives a rule for each novel site from nothing but a book address
 * (the iOS `testDerivesWorkingRulesFromScratch`): the hand rule only finds a book on the front
 * page, and the derived rule's catalog is checked against the hand rule's. `--es mode trace
 * --es sites a,b` logs every intermediate step of a derivation.
 */
class ProbeActivity : ComponentActivity() {
    private sealed class Check(val site: String, val book: String) {
        class Info(site: String, book: String, val title: String) : Check(site, book)

        /** [first] and [last] are chapter titles; null where the notes did not record one. */
        class Catalog(site: String, book: String, val count: Int, val first: String? = null, val last: String? = null) :
            Check(site, book)

        class Chapter(site: String, book: String, val chapter: String, val paragraphs: Int?, val chars: Int?) :
            Check(site, book)
    }

    // Each expectation is quoted from that site's notes, measured on iOS on 2026-09-26.
    private val checks = listOf(
        Check.Chapter("85novel", "1001614", "832874", 67, 2260),
        Check.Chapter("85novel", "8826826", "8700896", 81, 2017),
        Check.Chapter("wfxs", "222982", "75886633", 33, 1106),
        Check.Chapter("wfxs", "143330", "57910239", 91, 4683),
        Check.Chapter("cxyqw", "35822", "384118", 133, 5698),
        Check.Chapter("cxyqw", "12600", "127578", 6, 560),
        Check.Chapter("czbooks", "s6ojkc", "s6675fe9", null, null),
        Check.Catalog("cxyqw", "12600", 33, "第一章 重生拒當皇家人(1)", "後記"),
        Check.Catalog("qimao", "143170", 1279),
        Check.Info("czbooks", "s6ojkc", "《青山》"),
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val fetcher = WebFetcher(this)
        setContentView(fetcher.webView)
        lifecycleScope.launch {
            when (intent.getStringExtra("mode")) {
                "derive" -> intent.getStringExtra("url")?.let { deriveOne(fetcher, it) }
                    ?: deriveAll(fetcher, intent.getStringExtra("sites")?.split(",").orEmpty())
                "trace" -> traceDerivation(fetcher, intent.getStringExtra("sites")?.split(",").orEmpty())
                else -> runAll(BookService(fetcher))
            }
        }
    }

    // Internal storage, filled through run-as: files adb pushes into the app's external
    // directory belong to the shell user, and scoped storage keeps the app from reading them.
    private fun handRules(): Map<String, SiteRule> {
        val dir = File(filesDir, "sites")
        val rules = dir.listFiles { f -> f.extension == "json" }.orEmpty()
            .map { SiteRule.decode(it.readText()) }
            .associateBy { it.id }
        log(JSONObject().put("rules", rules.size).put("dir", dir.path))
        return rules
    }

    /** Books the probe above has read live, used by the trace mode. */
    private val derivations = listOf(
        "85novel" to "1001614", "wfxs" to "222982", "cxyqw" to "12600", "czbooks" to "s6ojkc", "qimao" to "143170",
    )

    @Serializable
    private data class Links(val hrefs: List<String>)

    /**
     * The iOS `LiveSiteRules.discoverBookId`: the first link on the site's front page that the
     * hand rule reads a book id from and not a chapter id. Discovered rather than fixed, as iOS
     * does, so the two platforms are measured the same way.
     */
    private suspend fun discoverBookId(rule: SiteRule, fetcher: WebFetcher): String? {
        val script = "(function () { return { hrefs: Array.prototype.slice.call(document.querySelectorAll('a[href]'))" +
            ".map(function (a) { return a.href; }) }; })()"
        val links = fetcher.fetch("https://${rule.host}/", script, Links.serializer())
        return links.hrefs.firstNotNullOfOrNull { href ->
            if (!rule.matches(href) || rule.chapterId(href) != null) null else rule.bookId(href)
        }
    }

    private suspend fun deriveAll(fetcher: WebFetcher, sites: List<String>) {
        val service = BookService(fetcher)
        val rules = handRules().values.filter { it.kind == SiteRule.Kind.NOVEL && (sites.isEmpty() || it.id in sites) }
            .sortedBy { it.id }
        for (hand in rules) {
            val row = JSONObject().put("site", hand.id)
            val start = SystemClock.elapsedRealtime()
            try {
                val book = discoverBookId(hand, fetcher) ?: throw IllegalStateException("no book on the front page")
                val url = hand.bookUrl(book)
                row.put("url", url)
                delay(2_000)
                val draft = RuleDeriver(fetcher, emptyList()).derive(url)
                val derived = draft.rule
                val id = derived.bookId(url)
                row.put("bookId", id).put("title", draft.preview.bookTitle).put("previewChapters", draft.preview.chapterCount)
                    .put("content", derived.chapter?.contentSelectors?.firstOrNull() ?: "(heuristic)")
                    .put("excerpt", (draft.preview.evidence as? RuleDeriver.Preview.Evidence.Text)?.excerpt?.take(40))
                delay(2_000)
                val derivedCount = service.catalog(derived, id!!).size
                delay(2_000)
                val handCount = service.catalog(hand, book).size
                row.put("catalog", derivedCount).put("handCatalog", handCount)
                    .put("ok", id == book && derivedCount == handCount)
            } catch (e: Exception) {
                row.put("error", "${e.javaClass.simpleName}: ${e.message}").put("ok", false)
            }
            log(row.put("ms", SystemClock.elapsedRealtime() - start))
            delay(2_000)
        }
        log(JSONObject().put("done", true))
    }

    /** `--es url` with derive: one book page as pasted, installed rules ignored — for a book a site broke. */
    private suspend fun deriveOne(fetcher: WebFetcher, url: String) {
        val row = JSONObject().put("url", url)
        try {
            val draft = RuleDeriver(fetcher, emptyList()).derive(url)
            row.put("title", draft.preview.bookTitle).put("chapters", draft.preview.chapterCount)
                .put("firstChapter", draft.preview.firstChapterTitle)
                .put("excerpt", (draft.preview.evidence as? RuleDeriver.Preview.Evidence.Text)?.excerpt?.take(40))
                .put("ok", true)
        } catch (e: Exception) {
            row.put("error", "${e.javaClass.simpleName}: ${e.message}").put("ok", false)
        }
        log(row)
        log(JSONObject().put("done", true))
    }

    /** Every intermediate step of a derivation, for finding where one goes wrong. */
    private suspend fun traceDerivation(fetcher: WebFetcher, sites: List<String>) {
        val rules = handRules()
        for ((site, book) in derivations.filter { sites.isEmpty() || it.first in sites }) {
            val url = rules[site]?.bookUrl(book) ?: continue
            fun t(step: String, value: Any?) = log(JSONObject().put("site", site).put("step", step).put("value", value.toString()))
            try {
                val token = URLPatternInference.identifierTokens(url).firstOrNull() ?: ""
                val probe = RuleDeriver.pageProbe(token)
                val page = fetcher.fetch(url, probe, RuleDeriver.PageProbe.serializer())
                t("token", token)
                t("page", "href=${page.href} doc=${page.docTitle} metas=${page.metas.keys}")
                page.groups.forEach { g -> t("group", "${g.container} n=${g.hrefs.size} ${g.hrefs.take(3)}") }
                t("catalogLinks", page.catalogLinks)
                t("sameBookLinks", page.sameBookLinks.take(8))
                var best = RuleDeriver.bestCandidate(page, url, url)
                t("best", best?.let { "${it.group.container} n=${it.chapters.size} ${it.inferred}" })
                for (followed in RuleDeriver.followUps(page, url).take(2)) {
                    delay(2_000)
                    val next = fetcher.fetch(followed, probe, RuleDeriver.PageProbe.serializer())
                    next.groups.forEach { g -> t("followed.group", "$followed ${g.container} n=${g.hrefs.size} ${g.hrefs.take(2)}") }
                    val candidate = RuleDeriver.bestCandidate(next, url, followed)
                    t("followed.best", "$followed → ${candidate?.chapters?.size}")
                    if (candidate != null && candidate.chapters.size > (best?.chapters?.size ?: 0)) best = candidate
                }
                val chapters = best?.chapters ?: continue
                val order = RuleDeriver.order(chapters.map { it.second })
                val first = if (order == SiteRule.Catalog.Order.DESCENDING) chapters.last() else chapters.first()
                t("first", "$order $first")
                delay(2_000)
                val cp = fetcher.fetch(first.first, RuleDeriver.CHAPTER_PROBE, RuleDeriver.ChapterProbe.serializer())
                t("chapterProbe", cp)
            } catch (e: Exception) {
                t("error", "${e.javaClass.simpleName}: ${e.message}")
            }
            delay(2_000)
        }
        log(JSONObject().put("done", true))
    }

    private suspend fun runAll(service: BookService) {
        val rules = handRules()
        for (check in checks) {
            val rule = rules[check.site]
            val row = JSONObject().put("site", check.site).put("book", check.book)
            if (rule == null) {
                log(row.put("error", "no rule"))
                continue
            }
            val start = SystemClock.elapsedRealtime()
            try {
                when (check) {
                    is Check.Info -> {
                        val info = service.info(rule, check.book)
                        row.put("check", "info").put("title", info.title).put("author", info.author)
                            .put("ok", info.title == check.title)
                    }
                    is Check.Catalog -> {
                        val entries = service.catalog(rule, check.book)
                        row.put("check", "catalog").put("count", entries.size).put("expectCount", check.count)
                            .put("first", entries.first().title).put("last", entries.last().title)
                            .put("ok", entries.size == check.count &&
                                (check.first == null || entries.first().title == check.first) &&
                                (check.last == null || entries.last().title == check.last))
                    }
                    is Check.Chapter -> {
                        val paragraphs = service.chapterParagraphs(rule, rule.chapterUrl(check.book, check.chapter)).paragraphs
                        val chars = paragraphs.sumOf { it.length }
                        row.put("check", "chapter").put("chapter", check.chapter)
                            .put("paragraphs", paragraphs.size).put("expectParagraphs", check.paragraphs)
                            .put("chars", chars).put("expectChars", check.chars)
                            .put("head", paragraphs.first().take(30)).put("tail", paragraphs.last().takeLast(30))
                            .put("ok", check.paragraphs == null || (paragraphs.size == check.paragraphs && chars == check.chars))
                    }
                }
            } catch (e: Exception) {
                row.put("error", "${e.javaClass.simpleName}: ${e.message}").put("ok", false)
            }
            log(row.put("ms", SystemClock.elapsedRealtime() - start))
            delay(2_000) // these hosts turn away hits that come too close together
        }
        log(JSONObject().put("done", true))
    }

    private fun log(line: JSONObject) {
        Log.i("Probe", line.toString())
    }
}
