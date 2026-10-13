package com.zeyanlin.novelreader.network

import android.annotation.SuppressLint
import android.content.Context
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.json.Json
import kotlin.coroutines.resume

/**
 * Reads markup that came out of a file rather than off a site — the iOS import web view. Its own
 * view, never [WebFetcher]'s: that one carries the sites' cookies and is busy with them.
 *
 * iOS turns JavaScript off for the document; Android cannot, because `evaluateJavascript` needs
 * it on. What a book's own script could do is fenced instead: no network at all, no file or
 * content access, and every navigation refused. One per import, destroyed after.
 */
@SuppressLint("SetJavaScriptEnabled")
class ImportView(context: Context) {
    private val json = Json { ignoreUnknownKeys = true }
    private var loaded: CompletableDeferred<Unit>? = null

    private val view = WebView(context).apply {
        settings.javaScriptEnabled = true
        settings.blockNetworkLoads = true
        settings.allowFileAccess = false
        settings.allowContentAccess = false
        webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = true

            override fun onPageFinished(view: WebView, url: String) {
                loaded?.complete(Unit)
            }
        }
    }

    /**
     * Loads [html] as HTML, not XHTML — real EPUBs are not well-formed often enough that the
     * strict parser would lose chapters — then runs [script] and decodes what it returns.
     */
    suspend fun <T> extract(html: String, script: String, decoder: DeserializationStrategy<T>): T =
        withContext(Dispatchers.Main.immediate) {
            val done = CompletableDeferred<Unit>()
            loaded = done
            view.loadDataWithBaseURL(null, html, "text/html", "utf-8", null)
            try {
                withTimeout(TIMEOUT_MS) { done.await() }
            } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
                throw WebFetcher.FetchError.TimedOut()
            } finally {
                loaded = null
            }
            val raw = suspendCancellableCoroutine { cont -> view.evaluateJavascript(script) { cont.resume(it) } }
            if (raw == null || raw == "null") throw WebFetcher.FetchError.ExtractionFailed("extractor returned a non-JSON value")
            try {
                json.decodeFromString(decoder, raw)
            } catch (e: IllegalArgumentException) {
                throw WebFetcher.FetchError.ExtractionFailed(e.message ?: "undecodable extractor result")
            }
        }

    fun close() = view.destroy()

    private companion object {
        const val TIMEOUT_MS = 15_000L
    }
}
