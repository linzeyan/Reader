package com.zeyanlin.novelreader

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.content.IntentCompat
import com.zeyanlin.novelreader.ui.IosTheme
import com.zeyanlin.novelreader.ui.Root

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { IosTheme { Root() } }
        open(intent, restored = savedInstanceState != null)
    }

    // A file handed over while the app is already running (singleTask, see the manifest).
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        open(intent, restored = false)
    }

    private fun open(intent: Intent, restored: Boolean) {
        val stream = IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
        handedFile(intent.action, intent.data, stream, intent.flags, restored)?.let { (application as App).open(it) }
    }

    override fun onStart() {
        super.onStart()
        (application as App).becomeActive()
    }

    // The one activity going out of sight is the app leaving the screen — locked, or sent away.
    override fun onStop() {
        super.onStop()
        if (!isChangingConfigurations) (application as App).enterBackground()
    }
}

/**
 * The file another app handed over: "Open with" carries it as the intent's data, a share as its
 * stream. Null for anything else, and for an intent this launch did not just receive — one
 * replayed from recents, or handed back with a restored activity, was imported when it arrived.
 * Generic over the address only so a JVM test can drive it without an Android `Uri`.
 */
internal fun <T : Any> handedFile(action: String?, data: T?, stream: T?, flags: Int, restored: Boolean): T? = when {
    restored || flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0 -> null
    action == Intent.ACTION_VIEW -> data
    action == Intent.ACTION_SEND -> stream
    else -> null
}
