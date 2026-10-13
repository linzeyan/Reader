package com.zeyanlin.novelreader.services

import com.zeyanlin.novelreader.siterules.SiteRule
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.security.MessageDigest

/**
 * The installed rule files, one JSON file each in [directory] — the iOS `SiteStore`. The app
 * ships no sites: every rule arrives from the reader.
 */
class SiteStore(private val directory: File) {
    class ImportError(message: String) : Exception(message)

    private val state = MutableStateFlow(load())
    val rules: StateFlow<List<SiteRule>> = state

    fun rule(id: String): SiteRule? = state.value.firstOrNull { it.id == id }

    /** Which installed rule can read this URL — the entry point for "paste a link". */
    fun ruleMatching(url: String): SiteRule? = state.value.firstOrNull { it.matches(url) }

    /** Checks and installs a rule file, replacing any rule with the same id. */
    fun import(text: String): SiteRule {
        val rule = try {
            SiteRule.decode(text)
        } catch (e: IllegalArgumentException) {
            throw ImportError("規則檔格式不正確。")
        }
        // The same refusals as iOS, for the same reasons (SiteStore.importRule there).
        val problem = when {
            rule.id == LOCAL_SITE_ID -> "the source id \"$LOCAL_SITE_ID\" is reserved"
            rule.kind == SiteRule.Kind.NOVEL && rule.chapter == null -> "a novel source needs a \"chapter\" block"
            rule.kind == SiteRule.Kind.COMIC && rule.images == null -> "a comic source needs an \"images\" block"
            rule.kind == SiteRule.Kind.FEED -> "a feed is subscribed to by address, not by rule"
            // A rule for a trusted site must not put a lookalike login form in front of the reader.
            rule.signIn != null && !signInStaysOnSite(rule) -> "the \"signIn\" address must be on ${rule.host}"
            else -> null
        }
        if (problem != null) throw ImportError("規則檔格式不正確：$problem")
        directory.mkdirs()
        // Re-encoded rather than copied: what lands on disk is something this build reads back.
        file(rule.id).writeText(pretty.encodeToString(SiteRule.serializer(), rule))
        state.value = load()
        return rule
    }

    /**
     * Fetches a rule someone published and installs it. A plain HTTP request rather than the
     * shared [com.zeyanlin.novelreader.network.WebFetcher]: a rule file is a static document,
     * and routing it through the one web view would evict whatever page a download is reading.
     */
    suspend fun importRemote(url: String): SiteRule {
        val scheme = runCatching { URI(url).scheme?.lowercase() }.getOrNull()
        if (scheme != "http" && scheme != "https") throw ImportError("無法讀取這個檔案。")
        val text = withContext(Dispatchers.IO) {
            val connection = try {
                URL(url).openConnection() as HttpURLConnection
            } catch (e: Exception) {
                throw ImportError("無法讀取這個檔案。")
            }
            try {
                connection.connectTimeout = 20_000
                connection.readTimeout = 20_000
                val status = connection.responseCode
                if (status !in 200..299) throw ImportError("規則檔格式不正確（HTTP $status）。")
                connection.inputStream.use { it.readBytes().decodeToString() }
            } catch (e: ImportError) {
                throw e
            } catch (e: Exception) {
                throw ImportError("無法讀取這個檔案。")
            } finally {
                connection.disconnect()
            }
        }
        return import(text)
    }

    fun remove(id: String) {
        file(id).delete()
        state.value = load()
    }

    /** Where a rule is stored — and so what sharing it hands over, as iOS shares the file itself. */
    fun file(id: String) = File(directory, safeComponent(id) + ".json")

    private fun load(): List<SiteRule> =
        directory.listFiles { f -> f.extension == "json" }.orEmpty()
            .mapNotNull { runCatching { SiteRule.decode(it.readText()) }.getOrNull() }
            .sortedBy { it.name }

    private fun signInStaysOnSite(rule: SiteRule): Boolean {
        val host = runCatching { URI(rule.signIn!!.url).host }.getOrNull() ?: return false
        return host.equals(rule.host, ignoreCase = true)
    }

    companion object {
        /** Reserved on iOS for books imported from files; refused here so the two stay compatible. */
        const val LOCAL_SITE_ID = "local"

        private val pretty = Json(SiteRule.json) { prettyPrint = true }

        /** iOS `ChapterFileStore.safeComponent`: a file name that cannot escape its directory. */
        fun safeComponent(raw: String): String {
            val sanitised = raw.map { if (it.isLetterOrDigit() || it == '-' || it == '_') it else '_' }.joinToString("")
            if (sanitised == raw && sanitised.isNotEmpty()) return sanitised
            val digest = MessageDigest.getInstance("SHA-256").digest(raw.toByteArray())
                .take(6).joinToString("") { "%02x".format(it) }
            return sanitised.take(48) + "-" + digest
        }
    }
}
