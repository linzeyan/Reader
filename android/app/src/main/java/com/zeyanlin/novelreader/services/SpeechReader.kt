package com.zeyanlin.novelreader.services

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import com.zeyanlin.novelreader.App
import com.zeyanlin.novelreader.R
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.launch
import java.util.Locale

/** What is being listened to, as the notification and the lock screen describe it. */
data class SpeechBook(val id: String, val title: String)

/**
 * One stretch of listening: the reader pressed the headphones on this book, here, in this script
 * and at this pace — the iOS `SpeechSession`.
 *
 * @param note called as each sentence begins: the only record a locked phone keeps of where the
 * reader got to, since nothing is drawn to report a position.
 */
class SpeechSession(
    val book: SpeechBook,
    val chapterIndex: Int,
    val anchor: TextAnchor,
    val script: ChineseScript,
    val rate: Float,
    val supply: suspend (Int) -> List<SpokenSentence>?,
    val note: (SpokenSentence) -> Unit,
)

/**
 * Reading the book out loud — the iOS `SpeechReader`, on Android's `TextToSpeech`. Owned by the
 * app rather than the reader screen, because listening outlives looking: a phone put in a pocket
 * leaves the screen drawn by nobody. A foreground service with a media session keeps the process
 * and the headphone buttons while it reads.
 *
 * Unlike iOS there is no pausing mid-word: Android's engines can only stop. So every pause,
 * the reader's or the system's, says the interrupted sentence again from its head.
 */
class SpeechReader(private val context: Context, private val fail: (String) -> Unit) {
    enum class State { IDLE, SPEAKING, PAUSED }

    var state by mutableStateOf(State.IDLE)
        private set

    /** What is being said: the band on the page and the page that follows the voice are this. */
    var current by mutableStateOf<SpokenSentence?>(null)
        private set

    /** Which book, so another book's reader is not shown this one's sentence. */
    var book by mutableStateOf<SpeechBook?>(null)
        private set

    /** When the voice stops of its own accord, after the run in its mouth; a moment, so changing the pace does not restart it. */
    var sleepsAt by mutableStateOf<Long?>(null)

    val isSpeaking get() = state == State.SPEAKING

    /** One utterance and the sentences it says: the engine reports by utterance and offset, never by place in the book. */
    private class Chunk(val id: String, val sentences: List<SpokenSentence>, val starts: List<Int>) {
        // The last starting at or before: the engine reports a word, inside a sentence.
        fun sentence(at: Int) = starts.indexOfLast { it <= at }.takeIf { it >= 0 }?.let { sentences[it] }
    }

    private val main = Handler(Looper.getMainLooper())
    private val scope = MainScope()
    private var engine: TextToSpeech? = null
    private var ready = CompletableDeferred<Boolean>()
    private var sequence: SpeechSequence? = null
    private val queue = ArrayList<Chunk>()
    private var filling: Job? = null
    private var serial = 0
    private var locale: Locale? = null
    private var script = ChineseScript(ChineseScript.Depth.OFF, ChineseScript.Target.TRADITIONAL)
    private var rate = 1f
    private var note: ((SpokenSentence) -> Unit)? = null

    /** The reader paused from the page: the notification and the audio are let go, and resuming starts the service again. */
    private var putDown = false

    /** The system took the audio, and only a pause it made may be undone by it handing the audio back. */
    private var pausedBySystem = false

    private val audio = context.getSystemService(AudioManager::class.java)
    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()

    // Paused rather than ducked: speech at a third of its volume under a navigation prompt is
    // not followable, where music would be.
    private val focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
        .setAudioAttributes(attributes).setWillPauseWhenDucked(true)
        .setOnAudioFocusChangeListener({ focusChanged(it) }, main).build()

    /** The headphones came out: reading the rest aloud to a carriage full of strangers is what nobody wants. */
    private val noisy = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (state == State.SPEAKING) hold()
        }
    }
    private var listening = false

    private val session by lazy {
        MediaSession(context, "speech").apply {
            setCallback(
                object : MediaSession.Callback() {
                    override fun onPlay() = resume()

                    override fun onPause() = hold()

                    override fun onStop() = stop()
                },
                main,
            )
        }
    }

    fun start(session: SpeechSession) {
        stop()
        book = session.book
        script = session.script
        rate = session.rate
        note = session.note
        val sequence = SpeechSequence(session.supply)
        this.sequence = sequence
        // Before the chapter is read: the control just pressed has to answer for the press.
        state = State.SPEAKING
        takeTheAudio()
        startService()
        publish()
        filling = scope.launch {
            if (!engine().let { ready.await() }) {
                stop()
                fail("這台裝置沒有可用的朗讀引擎。")
                return@launch
            }
            if (!sequence.begin(session.chapterIndex, session.anchor)) {
                stop()
                return@launch
            }
            filling = null
            fill()
        }
    }

    /**
     * The reader's own pause, on the page: the book is put down — off the notification shade,
     * audio handed back — since a reader who stopped with the page open has not asked to be
     * offered it from outside. A pause from anywhere else is [hold].
     */
    fun pause() {
        if (state != State.SPEAKING) return
        state = State.PAUSED
        putDown = true
        pausedBySystem = false
        engine?.stop()
        letGo()
    }

    /** A pause from the notification, headphones or the system: the book stays on the shade with a play button. */
    private fun hold() {
        if (state != State.SPEAKING) return
        state = State.PAUSED
        pausedBySystem = false
        engine?.stop()
        publish()
    }

    fun resume() {
        if (state != State.PAUSED) return
        pausedBySystem = false
        state = State.SPEAKING
        takeTheAudio()
        if (putDown) {
            putDown = false
            startService()
        }
        publish()
        resayFromCurrent()
        fill()
    }

    fun stop() {
        val wasReading = state != State.IDLE
        state = State.IDLE
        current = null
        book = null
        note = null
        sequence = null
        filling?.cancel()
        filling = null
        queue.clear()
        locale = null
        sleepsAt = null
        pausedBySystem = false
        val wasPutDown = putDown
        putDown = false
        engine?.stop()
        if (wasReading && !wasPutDown) letGo()
    }

    /** A new pace, for the sentence in the voice's mouth too: an utterance's rate is fixed once handed over. */
    fun setRate(rate: Float) {
        if (rate == this.rate) return
        this.rate = rate
        resayFromCurrent()
    }

    /** Hands what is owed back to the engine from the sentence being said — never from its paragraph's head. */
    private fun resayFromCurrent() {
        if (state != State.SPEAKING) return
        val owed = queue.flatMap { it.sentences }
        val from = current?.let { owed.indexOf(it) }?.takeIf { it >= 0 } ?: 0
        queue.clear()
        engine?.stop()
        for (run in SpeechScript.runs(owed.drop(from))) say(run)
    }

    /** Tops the engine up to one run ahead of the one being said, loading chapters as needed. */
    private fun fill() {
        if (state != State.SPEAKING || filling?.isActive == true) return
        filling = scope.launch {
            while (state == State.SPEAKING && !sleptIn && queue.size <= READ_AHEAD) {
                val run = sequence?.takeRun().orEmpty()
                if (run.isEmpty()) break
                say(run)
            }
            // The book ran out under the voice, or the timer rang: the session goes back.
            if (state == State.SPEAKING && queue.isEmpty()) stop()
        }
    }

    private val sleptIn get() = sleepsAt?.let { it <= System.currentTimeMillis() } ?: false

    private fun say(run: List<SpokenSentence>) {
        val engine = engine ?: return
        for (piece in SpeechScript.pieces(run, TextToSpeech.getMaxSpeechInputLength())) {
            val (text, starts) = SpeechScript.spoken(piece)
            val chunk = Chunk("u${++serial}", piece, starts)
            queue += chunk
            // Loaded after the voice was paused: kept for resume, not said under the reader.
            if (putDown || state != State.SPEAKING) continue
            // Per utterance, as iOS chooses a voice: a Mandarin voice reading an English feed is unintelligible.
            val wanted = if (SpeechScript.hasHan(text)) mandarin() else Locale.getDefault()
            if (wanted != locale) {
                if (engine.setLanguage(wanted) < TextToSpeech.LANG_AVAILABLE) {
                    stop()
                    fail("這台裝置沒有${wanted.displayName}的朗讀聲音，請到「設定 › 朗讀聲音」下載。")
                    return
                }
                locale = wanted
            }
            engine.setSpeechRate(rate)
            engine.speak(text, TextToSpeech.QUEUE_ADD, null, chunk.id)
            // A breath between runs; inside one, its punctuation and line breaks already pause.
            engine.playSilentUtterance(150, TextToSpeech.QUEUE_ADD, GAP)
        }
    }

    /** The script the page is drawn in; with conversion off, whatever the device would guess. */
    private fun mandarin(): Locale {
        val target = if (script.depth == ChineseScript.Depth.OFF) ChineseScript.deviceDefault() else script.target
        return if (target == ChineseScript.Target.SIMPLIFIED) Locale.SIMPLIFIED_CHINESE else Locale.TRADITIONAL_CHINESE
    }

    private fun engine(): TextToSpeech = engine ?: TextToSpeech(context) { ready.complete(it == TextToSpeech.SUCCESS) }.also {
        it.setAudioAttributes(attributes)
        it.setOnUtteranceProgressListener(
            object : UtteranceProgressListener() {
                override fun onStart(id: String) {
                    main.post { began(id) }
                }

                // Where in the utterance the voice is, which is what makes a paragraph safe to hand over whole.
                override fun onRangeStart(id: String, start: Int, end: Int, frame: Int) {
                    main.post { saying(id, start) }
                }

                override fun onDone(id: String) {
                    main.post { finished(id) }
                }

                @Deprecated("Deprecated in Java")
                override fun onError(id: String) {
                    main.post { failed(id, TextToSpeech.ERROR) }
                }

                override fun onError(id: String, code: Int) {
                    main.post { failed(id, code) }
                }
            },
        )
        engine = it
    }

    private fun began(id: String) {
        // The head of the run, refined by `saying` where the engine reports ranges — not every one does.
        queue.firstOrNull { it.id == id }?.sentences?.firstOrNull()?.let(::arriveAt)
    }

    private fun saying(id: String, offset: Int) {
        queue.firstOrNull { it.id == id }?.sentence(offset)?.let(::arriveAt)
    }

    private fun arriveAt(sentence: SpokenSentence) {
        if (sentence == current) return
        val newChapter = current?.chapterIndex != sentence.chapterIndex
        current = sentence
        note?.invoke(sentence)
        if (newChapter) publish()
    }

    private fun finished(id: String) {
        val index = queue.indexOfFirst { it.id == id }
        if (index < 0) return
        // Everything before it too: a queue that leaks entries would refuse to be topped up.
        repeat(index + 1) { queue.removeAt(0) }
        fill()
    }

    /** An engine that cannot say what it was given would otherwise walk the book in silence, writing progress. */
    private fun failed(id: String, code: Int) {
        if (queue.none { it.id == id } || state != State.SPEAKING) return
        stop()
        fail(
            when (code) {
                // A fresh device's engine reaches for a network voice while its own is still downloading.
                TextToSpeech.ERROR_NETWORK, TextToSpeech.ERROR_NETWORK_TIMEOUT, TextToSpeech.ERROR_NOT_INSTALLED_YET ->
                    "這個語言的朗讀聲音還沒下載好。請稍後再試，或先到「設定 › 朗讀聲音」下載。"
                else -> "朗讀中斷了：語音引擎無法讀出這段文字。"
            },
        )
    }

    // The audio and everything outside the app

    private fun takeTheAudio() {
        audio.requestAudioFocus(focus)
        session.isActive = true
        claimMediaButtons()
        if (!listening) {
            ContextCompat.registerReceiver(context, noisy, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY), ContextCompat.RECEIVER_NOT_EXPORTED)
            listening = true
        }
    }

    /**
     * The voice is played by the engine's process, and Android sends headphone buttons to the
     * session of whichever app last played audio itself — so without this, nobody's. A tenth of a
     * second of this app's own silence makes it that app.
     */
    private fun claimMediaButtons() {
        val bytes = 1600 // 100 ms of 16-bit mono at 8 kHz
        val track = AudioTrack.Builder()
            .setAudioAttributes(attributes)
            .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(8000).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
            .setTransferMode(AudioTrack.MODE_STATIC).setBufferSizeInBytes(bytes).build()
        track.write(ByteArray(bytes), 0, bytes)
        track.play()
        main.postDelayed({ track.release() }, 500)
    }

    /** Hands the audio back and takes the book off the shade: holding it would keep somebody's music paused. */
    private fun letGo() {
        audio.abandonAudioFocusRequest(focus)
        session.setPlaybackState(PlaybackState.Builder().setState(PlaybackState.STATE_STOPPED, 0, 0f).build())
        session.isActive = false
        if (listening) {
            context.unregisterReceiver(noisy)
            listening = false
        }
        context.stopService(Intent(context, SpeechService::class.java))
    }

    private fun focusChanged(change: Int) {
        when (change) {
            // A phone call, an alarm, a navigation prompt: handed back when it is over.
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> if (state == State.SPEAKING) {
                hold()
                pausedBySystem = true
            }
            // Another app started playing: nothing will hand this back.
            AudioManager.AUDIOFOCUS_LOSS -> hold()
            // Only a voice the system stopped may be started by the system; a reader who paused stays paused.
            AudioManager.AUDIOFOCUS_GAIN -> if (pausedBySystem) resume()
        }
    }

    private fun startService() {
        ContextCompat.startForegroundService(context, Intent(context, SpeechService::class.java))
    }

    /** The session's state and the notification, for the lock screen, the shade and a car's dashboard. */
    private fun publish() {
        val book = book ?: return
        if (putDown) return
        session.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, current?.chapterTitle ?: book.title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, book.title).build(),
        )
        // No skipping: "next" in a book read sentence by sentence has no meaning to promise.
        session.setPlaybackState(
            PlaybackState.Builder()
                .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_STOP)
                .setState(if (isSpeaking) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED, PlaybackState.PLAYBACK_POSITION_UNKNOWN, if (isSpeaking) 1f else 0f)
                .build(),
        )
        context.getSystemService(NotificationManager::class.java).notify(NOTIFICATION, notification() ?: return)
    }

    /** What the shade shows while a book is being read; null when none is. */
    fun notification(): Notification? {
        val book = book ?: return null
        if (state == State.IDLE || putDown) return null
        channel()
        fun service(action: String, code: Int) = PendingIntent.getForegroundService(
            context, code, Intent(context, SpeechService::class.java).setAction(action), PendingIntent.FLAG_IMMUTABLE,
        )
        val open = context.packageManager.getLaunchIntentForPackage(context.packageName)?.let {
            PendingIntent.getActivity(context, 0, it, PendingIntent.FLAG_IMMUTABLE)
        }
        // Android 13 draws the controls from the session; the action is for the versions before it.
        val toggle = if (isSpeaking) {
            Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(context, R.drawable.ic_pause), "暫停朗讀", service(TOGGLE, 1)).build()
        } else {
            Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(context, R.drawable.ic_play), "開始朗讀", service(TOGGLE, 1)).build()
        }
        return Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_speech)
            .setContentTitle(current?.chapterTitle ?: book.title)
            .setContentText(book.title)
            .setContentIntent(open)
            .setDeleteIntent(service(STOP, 2))
            .setOngoing(isSpeaking)
            .addAction(toggle)
            .setStyle(Notification.MediaStyle().setMediaSession(session.sessionToken).setShowActionsInCompactView(0))
            .build()
    }

    /** For a service started just as the reading stopped: it must go foreground once before it may stop. */
    fun placeholder(): Notification {
        channel()
        return Notification.Builder(context, CHANNEL).setSmallIcon(R.drawable.ic_speech).setContentTitle("朗讀").build()
    }

    private fun channel() {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL) != null) return
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "朗讀", NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) })
    }

    /** From the notification's button or its dismissal. */
    fun handle(action: String?) {
        when (action) {
            TOGGLE -> if (isSpeaking) hold() else resume()
            STOP -> stop()
        }
    }

    companion object {
        /** How many runs wait behind the one being said: enough for a seam nobody hears, cheap to take back. */
        private const val READ_AHEAD = 1
        private const val GAP = "gap"
        const val NOTIFICATION = 7
        private const val CHANNEL = "speech"
        const val TOGGLE = "toggle"
        const val STOP = "stop"

        /** Android's own multiplier, 1 the engine's normal pace; narrower than it accepts, for iOS's reasons — slower stops sounding like speech, faster runs Mandarin's tones together. */
        val RATES = 0.6f..1.8f
    }
}

/**
 * Keeps the process, and its place on the shade, while a book is read with the screen off. Holds
 * nothing itself: the reader owns the voice, and this only shows what it is doing.
 */
class SpeechService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val speech = (application as App).speech
        speech.handle(intent?.action)
        val notification = speech.notification()
        // Foreground before anything else: a service started that way and stopped without it crashes the app.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(SpeechReader.NOTIFICATION, notification ?: speech.placeholder(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(SpeechReader.NOTIFICATION, notification ?: speech.placeholder())
        }
        if (notification == null) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
        return START_NOT_STICKY
    }
}
