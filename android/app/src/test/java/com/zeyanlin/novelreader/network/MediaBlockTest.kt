package com.zeyanlin.novelreader.network

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The fetcher's web view refuses audio and video, as iOS's content rule does: ad video downloaded
 * out of the reader's data plan for nobody to watch. What a rule reads — pages, scripts, the
 * pictures a comic is made of — must still load, or the extractor sees a different page.
 */
class MediaBlockTest {
    @Test
    fun audioAndVideoAreRefusedAndWhatTheExtractorReadsIsNot() {
        assertTrue(isMedia("https://ads.example/creative/clip.MP4?sig=abc#t=1", emptyMap()))
        assertTrue(isMedia("https://cdn.example/live/index.m3u8", emptyMap()))
        assertTrue(isMedia("https://cdn.example/a/jingle.mp3", emptyMap()))
        // A player streaming from an address with no extension still asks for a byte range.
        assertTrue(isMedia("https://cdn.example/videoplayback?id=1", mapOf("range" to "bytes=0-")))

        assertFalse(isMedia("https://img9.8comic.com/4/103/471/001_RWq.jpg", emptyMap()))
        assertFalse(isMedia("https://www.8comic.com/online/new-103.html?ch=471", emptyMap()))
        assertFalse(isMedia("https://www.8comic.com/js/comicview.js", emptyMap()))
        // The file is the path's; a query that names one is still a script.
        assertFalse(isMedia("https://ads.example/player.js?src=clip.mp4", emptyMap()))
        assertFalse(isMedia("https://www.8comic.com/", emptyMap()))
    }
}
