package com.zeyanlin.novelreader.services

import kotlinx.coroutines.flow.MutableStateFlow
import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.temporal.ChronoUnit
import java.util.Locale
import java.util.concurrent.Callable
import java.util.concurrent.Executors

/**
 * The iOS `TraceLog`: what the app did, written to a file the reader can hand over — for the
 * questions only a device can answer. Off for everyone who was not asked to turn it on.
 *
 * Turning it off deletes everything it wrote, on the spot: no retention window, no expiry, the
 * switch is the whole policy, and the size cap bounds the cost of forgetting it.
 *
 * The file leaves the phone through a share sheet, so it holds counts, durations, byte sizes and
 * chapter indices — never a title, an author, an address, a search or a line of text. Every
 * [note] is bound by that; there is no redaction pass to catch a mistake afterwards.
 *
 * [on] is persisted by the caller: the session worth recording is a whole evening, and the app
 * is relaunched several times inside one. [stamp] is the build and device, without which a file
 * cannot be attributed to anything once it is out of the app.
 */
class TraceLog(private val directory: File, on: Boolean, private val stamp: String) {
    val isOn = MutableStateFlow(on)

    private val current = File(directory, "trace.log")
    private val rolled = File(directory, "trace-1.log")

    // One thread, off the caller's: lines land in the order they were noted, a read sees every
    // line noted before it, and the instrument is not the load on the paths it measures.
    private val writer = Executors.newSingleThreadExecutor { Thread(it, "trace").apply { isDaemon = true } }

    // Seconds since launch rather than wall clock; the boot line carries the one absolute time.
    private val startedAt = System.nanoTime()

    init {
        // A launch that finds the switch on is the second half of somebody's evening: it carries on
        // the same file rather than starting over.
        if (on) begin()
    }

    /** One line, if recording is on. Counts, timings and indices only — see the type's note. */
    fun note(line: String) {
        if (!isOn.value) return
        write(String.format(Locale.ROOT, "%9.1f %s\n", (System.nanoTime() - startedAt) / 1e9, line))
    }

    fun setOn(on: Boolean) {
        if (on == isOn.value) return
        isOn.value = on
        if (on) begin() else writer.execute { directory.deleteRecursively() }
    }

    /** The whole trace, oldest line first. Blocks until every line noted so far is on disk. */
    fun contents(): ByteArray = writer.submit(Callable { rolled.bytes() + current.bytes() }).get()

    fun size(): Long = writer.submit(Callable { rolled.length() + current.length() }).get()

    private fun begin() = write("      0.0 boot $stamp at=${Instant.now().truncatedTo(ChronoUnit.SECONDS)}\n")

    private fun write(text: String) = writer.execute {
        directory.mkdirs()
        current.appendText(text)
        // Rolled rather than truncated or overwritten: what is wanted is the last several hours,
        // and two files kept in turn hold between one and two full files of them.
        if (current.length() >= FILE_LIMIT) {
            rolled.delete()
            current.renameTo(rolled)
        }
    }

    private fun File.bytes() = if (exists()) readBytes() else ByteArray(0)

    companion object {
        /**
         * Per file, so four megabytes at the widest. A trace runs about 120 KB an hour, so this is
         * more than a week of evenings: it bounds a switch left on and forgotten, nothing more.
         */
        const val FILE_LIMIT = 2 * 1024 * 1024

        /** Dated like a backup: two of these in a folder have to be told apart by more than save order. */
        fun filename(day: LocalDate) = "novel-reader-trace-$day.txt"
    }
}
