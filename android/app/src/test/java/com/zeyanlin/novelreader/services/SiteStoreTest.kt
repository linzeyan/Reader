package com.zeyanlin.novelreader.services

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class SiteStoreTest {
    @get:Rule
    val folder = TemporaryFolder()

    private val czbooks: String by lazy {
        File(System.getProperty("user.dir"), "../../../dev_docs/novel_reader/sites/czbooks.json").canonicalFile.readText()
    }

    @Test
    fun anImportedRuleIsInstalledAndFoundByItsAddress() {
        val store = SiteStore(folder.root)
        store.import(czbooks)
        assertEquals(listOf("czbooks"), store.rules.value.map { it.id })
        assertEquals("czbooks", store.ruleMatching("https://czbooks.net/n/s6ojkc")?.id)
        // What lands on disk reads back after a restart.
        assertEquals(listOf("czbooks"), SiteStore(folder.root).rules.value.map { it.id })
        store.remove("czbooks")
        assertTrue(store.rules.value.isEmpty())
    }

    // Each refusal is a rule that would install fine and fail later, where nobody can act on it.
    @Test
    fun rulesThatCannotWorkAreRefusedAtTheDoor() {
        val store = SiteStore(folder.root)
        fun refused(json: String) = assertThrows(SiteStore.ImportError::class.java) { store.import(json) }
        refused("{ not json")
        val noChapterBlock = czbooks.replace("\"chapter\": {", "\"unusedChapter\": {")
        refused(noChapterBlock)
        refused(czbooks.replace("\"id\": \"czbooks\"", "\"id\": \"local\""))
        refused(czbooks.trimEnd().removeSuffix("}") + ", \"signIn\": {\"landsOn\": \"/login\", \"url\": \"https://evil.example/login\"} }")
        assertTrue(store.rules.value.isEmpty())
        // The cases above fail on their own fault, not on a broken fixture: fixed, each installs.
        store.import(czbooks.trimEnd().removeSuffix("}") + ", \"signIn\": {\"landsOn\": \"/login\", \"url\": \"https://czbooks.net/login\"} }")
        assertEquals(1, store.rules.value.size)
    }
}
