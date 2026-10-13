package com.zeyanlin.novelreader.services

import kotlinx.coroutines.delay
import kotlin.random.Random

/**
 * Spaces out the requests the app makes on its own initiative — the iOS `RequestPacer`. The gap
 * is random because a metronome-perfect interval is itself a fingerprint, and per host because
 * the politeness is owed to a server. Interactive work does not come through here.
 *
 * Main-thread only, like every caller.
 */
class RequestPacer(private val gap: ClosedFloatingPointRange<Double> = 0.9..2.6) {
    /** Reserved up front, so two callers on one host cannot wake together. */
    private val nextAllowed = mutableMapOf<String, Long>()

    suspend fun pace(host: String) {
        val now = System.nanoTime()
        val start = maxOf(now, nextAllowed[host] ?: now)
        nextAllowed[host] = start + (Random.nextDouble(gap.start, gap.endInclusive) * 1e9).toLong()
        if (start > now) delay((start - now) / 1_000_000)
    }

    /** Forgets every reservation; a new run should not inherit a cancelled one's gap. */
    fun reset() = nextAllowed.clear()
}
