package com.zeyanlin.novelreader

import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Which intents import a file. "Open with" and a share carry it in different places; and an
 * intent the system hands back again — the app reopened from recents, or restored — must not
 * import it a second time, or fail on a read grant long gone, with nobody having asked.
 */
class HandedFileTest {
    @Test
    fun openWithAndShareImportTheirFileAndAReplayedIntentImportsNothing() {
        assertEquals("view", handedFile(Intent.ACTION_VIEW, "view", null, 0, restored = false))
        assertEquals("stream", handedFile(Intent.ACTION_SEND, null, "stream", 0, restored = false))
        // The launcher's own start, and a notification's, hand over no file.
        assertNull(handedFile(Intent.ACTION_MAIN, null, null, 0, restored = false))

        assertNull(handedFile(Intent.ACTION_VIEW, "view", null, Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY, restored = false))
        assertNull(handedFile(Intent.ACTION_VIEW, "view", null, 0, restored = true))
    }
}
