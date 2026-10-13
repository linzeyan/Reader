package com.zeyanlin.novelreader.services

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.time.LocalDate

class TraceLogTest {
    @get:Rule
    val folder = TemporaryFolder()

    private val directory get() = File(folder.root, "Trace")

    private fun TraceLog.text() = String(contents())

    // Off for everyone who was not asked: nothing reaches the disk. And off is the whole retention
    // policy — stopping must leave nothing behind, or a file that leaves the phone outlives the switch.
    @Test
    fun recordsOnlyWhileOnAndStoppingDeletesEverything() {
        val trace = TraceLog(directory, on = false, stamp = "v=1")
        trace.note("dl start n=3")
        assertEquals(0L, trace.size())
        assertFalse(directory.exists())

        trace.setOn(true)
        trace.note("dl ok left=2")
        assertTrue(trace.text().contains("dl ok left=2"))

        trace.setOn(false)
        trace.note("dl ok left=1")
        assertEquals(0L, trace.size())
        assertFalse(directory.exists())
    }

    // An evening is several launches: a relaunch that finds the switch on carries on the same file,
    // or the run before a crash — the one that mattered — is lost.
    @Test
    fun aRelaunchWhileRecordingCarriesOnTheSameFile() {
        TraceLog(directory, on = true, stamp = "v=1").apply { note("bg enter busy=1") }.size()
        val relaunched = TraceLog(directory, on = true, stamp = "v=1")
        relaunched.note("bg leave resume=1")
        val text = relaunched.text()
        assertTrue(text.contains("bg enter busy=1"))
        assertEquals(2, Regex(" boot v=1 at=").findAll(text).count())
    }

    // A switch left on is bounded, and what is kept is the newest hours: a full file rolls aside
    // and the one before it goes, so the trace never passes two files and never loses its end.
    @Test
    fun aFullFileRollsSoTheNewestIsKeptAndTheSizeIsBounded() {
        val trace = TraceLog(directory, on = true, stamp = "v=1")
        val half = "x".repeat(TraceLog.FILE_LIMIT / 2)
        for (tag in listOf("first", "second", "third")) trace.note("$tag $half")
        val early = trace.text()
        assertTrue(early.indexOf("first") < early.indexOf("second") && early.indexOf("second") < early.indexOf("third"))

        trace.note("fourth $half")
        trace.note("fifth")
        val late = trace.text()
        assertFalse(late.contains("first"))
        assertFalse(late.contains("boot"))
        assertTrue(late.indexOf("third") < late.indexOf("fourth") && late.indexOf("fourth") < late.indexOf("fifth"))
        assertTrue(trace.size() < 2L * TraceLog.FILE_LIMIT + 1024)
    }

    // Read down a column by eye: the build and device first, then seconds right-aligned in one
    // width, and a dated plain-text name so two exports in a folder can be told apart.
    @Test
    fun theExportIsDatedPlainTextAttributedToItsBuild() {
        val trace = TraceLog(directory, on = true, stamp = "v=1.0(1) hw=Pixel_7 android=15")
        trace.note("dl done")
        val lines = trace.text().lines()
        assertTrue(lines[0], lines[0].matches(Regex("""      0\.0 boot v=1\.0\(1\) hw=Pixel_7 android=15 at=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ""")))
        assertTrue(lines[1], lines[1].matches(Regex("""[ \d]{6}\d\.\d dl done""")))
        assertEquals("", lines[2])
        assertEquals("novel-reader-trace-2026-10-13.txt", TraceLog.filename(LocalDate.of(2026, 10, 13)))
    }
}
