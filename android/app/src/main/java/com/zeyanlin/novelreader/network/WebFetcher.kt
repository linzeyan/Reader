package com.zeyanlin.novelreader.network

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.os.SystemClock
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import com.zeyanlin.novelreader.siterules.SiteRule
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import java.io.ByteArrayInputStream
import kotlin.coroutines.resume

/**
 * Loads pages with a real browser engine and extracts structured data from them — the iOS
 * `WebFetcher`, ported. The target sites sit behind Cloudflare, whose non-interactive check
 * only a JS engine clears; the engine keeps `cf_clearance` in its cookie store and every
 * later request rides on it. Nothing here attempts to solve or evade a check: when one will
 * not clear by itself, [webView] is handed to the UI so the reader can complete it.
 *
 * Where it deliberately differs from iOS, measured in docs/ANDROID.md (Cloudflare spike):
 * - **No user agent override.** WebView announces itself in client hints and
 *   `X-Requested-With` whatever the UA says, so claiming iPhone Safari (what iOS does) is
 *   a claim the engine contradicts — and the managed challenge never cleared under it.
 * - **A check gets 20 s to clear itself**, not 8: WebView took 12–18 s.
 *
 * Loads are serialised: one web view shows one page at a time, and hammering a challenged
 * host is exactly what must not happen. Everything runs on the main thread, as WebView requires.
 */
@SuppressLint("SetJavaScriptEnabled")
class WebFetcher(context: Context) {
    sealed class FetchError(message: String) : Exception(message) {
        /**
         * Only the reader can clear this, by doing something in [webView] — the iOS `needsTheUser`,
         * as a type. A screen that hands one kind to the sheet has to hand both: one that knew only
         * checks would swallow a sign-in and say "no title" where a password field belongs.
         */
        sealed class NeedsTheUser(val url: String, message: String) : FetchError(message)

        /** The host demands a check only a person can complete; present [webView]. */
        class ChallengePresented(url: String) : NeedsTheUser(url, "challenge at $url")

        /** The site turned a signed-out reader away; [url] is its sign-in page, already in [webView]. */
        class SignInRequired(url: String) : NeedsTheUser(url, "sign-in at $url")
        class NavigationFailed(description: String) : FetchError(description)
        class TimedOut : FetchError("timed out")
        class ExtractionFailed(description: String) : FetchError(description)
    }

    private val json = Json { ignoreUnknownKeys = true }
    private val mutex = Mutex()

    /** What the armed navigation waits for. Null when nothing is waiting. */
    private var waiter: CompletableDeferred<Unit>? = null
    private var waitingForBlank = false

    /**
     * Whether the awaited navigation has taken over the web view. Until it has, anything read
     * from the page belongs to the page before — which is whatever the last fetch left, and
     * perfectly capable of being complete, full of text, and the wrong document.
     */
    private var committed = false

    /** The last page asked for, for the Referer; the web view's own URL is about:blank by then. */
    private var cameFrom: Uri? = null

    val webView: WebView = WebView(context).apply {
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        // These sites carry video ads; nothing this view reads is ever watched.
        settings.mediaPlaybackRequiresUserGesture = true
        webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
                if ((url == BLANK) == waitingForBlank) committed = true
            }

            override fun onPageFinished(view: WebView, url: String) {
                if ((url == BLANK) == waitingForBlank) waiter?.complete(Unit)
            }

            // An ad that hands the page to an app (`intent://…`) would otherwise replace the
            // document with ERR_UNKNOWN_URL_SCHEME mid-fetch; declining it, as a browser does,
            // leaves the page loading. Seen once on quanben5 during a live derivation.
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                request.url.scheme !in setOf("http", "https", "about")

            // iOS's `fetch-block-media` rule. The playback flag keeps an ad video from playing;
            // this keeps it from downloading, out of the reader's data plan, for nobody to watch.
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
                if (!request.isForMainFrame && isMedia(request.url.toString(), request.requestHeaders)) {
                    WebResourceResponse("text/plain", "utf-8", ByteArrayInputStream(ByteArray(0)))
                } else {
                    null
                }

            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (!request.isForMainFrame) return
                // A superseded navigation is not a failure: several sites bounce the first
                // request, and the follow-up resumes the waiter (iOS ignores -999 the same way).
                val description = error.description.toString()
                if ("ERR_ABORTED" in description) return
                waiter?.completeExceptionally(FetchError.NavigationFailed(description))
            }
        }
    }

    /** Loads [url], waits for it, then evaluates [script] and decodes what it returns. */
    suspend fun <T> fetch(
        url: String,
        script: String,
        decoder: DeserializationStrategy<T>,
        waitFor: String? = null,
        timeoutMs: Long = 30_000,
        signIn: SiteRule.SignIn? = null,
    ): T = withContext(Dispatchers.Main.immediate) {
        mutex.withLock {
            navigate(timeoutMs, settleWhenReadable = true) { webView.loadUrl(url, headersFor(url)) }
            failIfChallenged()
            failIfTurnedAway(signIn, timeoutMs)
            waitForLateContent(waitFor)
            val value = evaluate(script, decoder)
            park()
            value
        }
    }

    /**
     * Loads [url], runs [submit] inside it, waits for the navigation that causes, then extracts.
     * For POST search forms: submitted from the page, the query is encoded in the document's own
     * charset — the only sane way to search the GBK and Big5 sites.
     */
    suspend fun <T> fetchSubmitting(
        url: String,
        submit: String,
        script: String,
        decoder: DeserializationStrategy<T>,
        waitFor: String? = null,
        timeoutMs: Long = 30_000,
        signIn: SiteRule.SignIn? = null,
    ): T = withContext(Dispatchers.Main.immediate) {
        mutex.withLock {
            navigate(timeoutMs, settleWhenReadable = true) { webView.loadUrl(url, headersFor(url)) }
            failIfChallenged()
            failIfTurnedAway(signIn, timeoutMs)
            navigate(timeoutMs, settleWhenReadable = true) { webView.evaluateJavascript(submit, null) }
            failIfChallenged()
            failIfTurnedAway(signIn, timeoutMs)
            waitForLateContent(waitFor)
            val value = evaluate(script, decoder)
            park()
            value
        }
    }

    /**
     * Same-host Referer, because two chapters read in a row look like that from the other end;
     * never across hosts, where it would tell one site what the reader did on another.
     */
    private fun headersFor(url: String): Map<String, String> {
        val target = Uri.parse(url)
        val previous = cameFrom
        cameFrom = target
        return if (previous != null && previous.host == target.host && previous != target) {
            mapOf("Referer" to previous.toString())
        } else {
            emptyMap()
        }
    }

    /**
     * Arms the waiter, runs [trigger], and waits for the navigation it causes. With
     * [settleWhenReadable], a document that has been readable for [GRACE_AFTER_READABLE_MS]
     * also ends the wait: on ad-heavy pages the load event comes much later than the text,
     * or never (cxyqw under one agent: 30 s, text complete all along).
     */
    private suspend fun navigate(
        timeoutMs: Long,
        settleWhenReadable: Boolean = false,
        toBlank: Boolean = false,
        trigger: () -> Unit,
    ) {
        val done = CompletableDeferred<Unit>()
        waiter = done
        waitingForBlank = toBlank
        committed = false
        try {
            coroutineScope {
                val settle = if (settleWhenReadable) launch { settleWhenReadable(); done.complete(Unit) } else null
                trigger()
                try {
                    withTimeout(timeoutMs) { done.await() }
                } finally {
                    settle?.cancel()
                }
            }
        } catch (e: TimeoutCancellationException) {
            throw FetchError.TimedOut()
        } finally {
            waiter = null
        }
    }

    private suspend fun settleWhenReadable() {
        var readableSince: Long? = null
        while (true) {
            delay(POLL_MS)
            if (!committed || !documentIsReadable()) {
                readableSince = null
                continue
            }
            val since = readableSince ?: SystemClock.elapsedRealtime().also { readableSince = it }
            if (SystemClock.elapsedRealtime() - since >= GRACE_AFTER_READABLE_MS) return
        }
    }

    /** A challenge page is text and a parsed document, and emphatically not the page asked for. */
    private suspend fun documentIsReadable(): Boolean = probe(
        """
        document.readyState !== 'loading'
          && !!document.body
          && (document.body.textContent || '').trim().length > 0
          && !($CHALLENGE_MARKERS)
        """,
    )

    /**
     * Hands the reader a check only once it is clear it will not clear itself. Polled rather
     * than awaited as a navigation, because clearing takes more than one hop and the last may
     * already have landed by the time this looks.
     */
    private suspend fun failIfChallenged() {
        if (!probe(CHALLENGE_MARKERS)) return
        val deadline = SystemClock.elapsedRealtime() + CHALLENGE_SELF_CLEAR_MS
        while (SystemClock.elapsedRealtime() < deadline) {
            delay(POLL_MS)
            if (!probe(CHALLENGE_MARKERS)) {
                waitUntilParsed()
                return
            }
        }
        throw FetchError.ChallengePresented(webView.url ?: "")
    }

    /**
     * Stops the fetch when the site bounced a signed-out reader to its members-only page — the
     * iOS `failIfTurnedAway`. Read from the landed address: the gate is a redirect out of a
     * `<head>` script, and the document it leaves holds nothing of the page asked for. That
     * redirect is often still in flight when the load reports finished (four of five gated
     * 8comic books), so an emptied document is waited on briefly; a page with any text never is.
     *
     * The web view is then taken to the sign-in form, because the sheet shows this view — the
     * one whose cookies the next fetch rides on — and the page it is on is a dead end. A form
     * that will not load still ends in "please sign in", which says more than its own failure.
     */
    private suspend fun failIfTurnedAway(signIn: SiteRule.SignIn?, timeoutMs: Long) {
        signIn ?: return
        if (!signIn.turnsAway(webView.url)) {
            if (!probe("!document.body || (document.body.textContent || '').trim().length === 0")) return
            // An empty trigger: what is awaited is the navigation the page started for itself.
            runCatching { navigate(GATE_SETTLE_MS) {} }
            if (!signIn.turnsAway(webView.url)) return
        }
        runCatching { navigate(timeoutMs) { webView.loadUrl(signIn.url, headersFor(signIn.url)) } }
        throw FetchError.SignInRequired(signIn.url)
    }

    /** The page a cleared check handed over to can still be streaming in. */
    private suspend fun waitUntilParsed() {
        val deadline = SystemClock.elapsedRealtime() + CHALLENGE_SELF_CLEAR_MS
        while (SystemClock.elapsedRealtime() < deadline) {
            if (probe("document.readyState !== 'loading'")) return
            delay(POLL_MS)
        }
    }

    /**
     * Holds extraction until the page matches [selector], for content filled in after load.
     * Never throws: the extractor already knows what an empty page means. A selector the page
     * cannot parse counts as found, so a typo in a rule costs nothing.
     */
    private suspend fun waitForLateContent(selector: String?) {
        if (selector.isNullOrEmpty()) return
        val quoted = json.encodeToString(String.serializer(), selector)
        val check = "(function () { try { return !!document.querySelector($quoted); } catch (e) { return true; } })()"
        val deadline = SystemClock.elapsedRealtime() + LATE_CONTENT_GRACE_MS
        while (SystemClock.elapsedRealtime() < deadline) {
            if (probe(check)) return
            delay(POLL_MS)
        }
    }

    /**
     * Parks on about:blank once a fetch has what it came for. Left on the page, its timers and
     * ad scripts keep burning CPU for the whole session. Cookies survive it.
     */
    private suspend fun park() {
        runCatching { navigate(PARK_TIMEOUT_MS, toBlank = true) { webView.loadUrl(BLANK) } }
    }

    private suspend fun <T> evaluate(script: String, decoder: DeserializationStrategy<T>): T {
        val raw = evaluateRaw(script)
        if (raw == null || raw == "null") throw FetchError.ExtractionFailed("extractor returned a non-JSON value")
        return try {
            json.decodeFromString(decoder, raw)
        } catch (e: IllegalArgumentException) {
            throw FetchError.ExtractionFailed(e.message ?: "undecodable extractor result")
        }
    }

    /** A boolean JS expression, evaluated against the current document. False on any failure. */
    private suspend fun probe(expression: String): Boolean =
        evaluateRaw("(function () { try { return !!($expression); } catch (e) { return false; } })()") == "true"

    private suspend fun evaluateRaw(script: String): String? = suspendCancellableCoroutine { cont ->
        webView.evaluateJavascript(script) { cont.resume(it) }
    }

    private companion object {
        const val BLANK = "about:blank"
        const val POLL_MS = 400L
        const val GRACE_AFTER_READABLE_MS = 5_000L
        const val CHALLENGE_SELF_CLEAR_MS = 20_000L
        const val LATE_CONTENT_GRACE_MS = 10_000L
        const val PARK_TIMEOUT_MS = 5_000L

        /** Long enough for a redirect already under way; short enough that a broken page does not hold the queue. */
        const val GATE_SETTLE_MS = 3_000L

        /** The iOS `WebFetcher.challengeMarkers`: Cloudflare's, and one site's own proof-of-work page. */
        val CHALLENGE_MARKERS = """
            !!window._cf_chl_opt
            || !!document.querySelector('script[src*="challenges.cloudflare.com"]')
            || !!document.querySelector('#challenge-form, #cf-challenge-running')
            || !!document.querySelector('script[src*="/__gatekeeper_challenge/"]')
        """.trimIndent()
    }
}

/**
 * Whether a request is for audio or video — what iOS's `resource-type: media` rule names. Android
 * hands over no resource type, so it is read from the two things a media load carries: a media
 * file's extension, or the `Range` header a player streams with. Images are left alone, as on
 * iOS: rules read `src` off them, and a blocked image is a page the extractor sees differently.
 */
internal fun isMedia(url: String, headers: Map<String, String>): Boolean {
    if (headers.keys.any { it.equals("Range", ignoreCase = true) }) return true
    val name = url.substringBefore('#').substringBefore('?').substringAfterLast('/')
    return name.substringAfterLast('.', "").lowercase() in MEDIA_EXTENSIONS
}

private val MEDIA_EXTENSIONS = setOf(
    "mp4", "m4v", "m4s", "mov", "webm", "ogv", "3gp", "m3u8", "mpd", "ts",
    "mp3", "m4a", "aac", "ogg", "oga", "opus", "wav", "flac",
)
