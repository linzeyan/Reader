package com.zeyanlin.novelreader.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.zeyanlin.novelreader.services.TraceLog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDate

/**
 * The iOS `DiagnosticsView`: turning the trace on, watching it catch something, and sending it.
 * The footers are half the screen: a recording that cannot be stopped without losing it, and a
 * file that leaves the phone, both need saying before anybody touches the switch.
 */
@Composable
fun DiagnosticsScreen() {
    val app = app()
    val nav = LocalNavigator.current
    val p = LocalPalette.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val on by app.trace.isOn.collectAsState()
    var size by remember { mutableLongStateOf(0L) }
    var confirmingStop by remember { mutableStateOf(false) }

    // The one number here moves while somebody watches: whoever just turned recording on came to
    // see it catch something. Restarted by the switch, so the number answers it at once.
    LaunchedEffect(on) {
        while (true) {
            size = withContext(Dispatchers.IO) { app.trace.size() }
            delay(2_000)
        }
    }

    // Set by "export first", so that a finished save is what stops the recording — and a cancelled
    // one leaves it running, since the evening it holds cannot be recorded again.
    var stopAfterExport by rememberSaveable { mutableStateOf(false) }
    val saver = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("text/plain")) { uri ->
        val stop = stopAfterExport
        stopAfterExport = false
        if (uri != null) scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    val data = app.trace.contents()
                    context.contentResolver.openOutputStream(uri, "wt")!!.use { it.write(data) }
                }
                if (stop) app.setTracing(false)
            } catch (e: Exception) {
                app.report(e, "App 正在匯出日誌。")
            }
        }
    }

    fun export(thenStop: Boolean) {
        stopAfterExport = thenStop
        saver.launch(TraceLog.filename(LocalDate.now()))
    }

    ListScreen("診斷日誌", onBack = nav::pop) {
        item {
            Cell(Edge.ONLY) {
                Text("記錄日誌", style = Type.body, color = p.label, modifier = Modifier.weight(1f))
                IosSwitch(on) { wanted ->
                    // Stopping deletes, and the reason anybody turned this on was to send it: a thumb
                    // on a switch is a cheap way to lose an evening that cannot be reproduced.
                    if (!wanted && size > 0) confirmingStop = true else app.setTracing(wanted)
                }
            }
        }
        footer("只在我們請你打開的時候打開。App 會把效能數字寫成一個檔案——閱讀時的記憶體、朗讀的節奏、螢幕有沒有照設定休眠。關閉記錄時檔案會被刪除。")
        gap()
        item { Cell(Edge.TOP) { Labeled("日誌大小", bytes(size)) } }
        item {
            val enabled = size > 0
            Cell(Edge.BOTTOM, onClick = { if (enabled) export(thenStop = false) }, chevron = false) {
                Icon(Symbols.SquareAndArrowUp, null, Modifier.size(22.dp), tint = if (enabled) p.accent else p.tertiary)
                Spacer(Modifier.width(12.dp))
                Text("匯出日誌", style = Type.body, color = if (enabled) p.accent else p.tertiary)
            }
        }
        footer("日誌裡只有數字：時間、次數、大小、章節編號。沒有書名、作者、網址、搜尋內容，也沒有任何一行書的內文。")
    }
    if (confirmingStop) {
        Alert(
            "關閉記錄會刪除日誌", "已經記錄的內容會被刪除，而且無法重來——那一段閱讀不會再發生第二次。要先匯出嗎？", "先匯出",
            onConfirm = {
                confirmingStop = false
                export(thenStop = true)
            },
            onDismiss = { confirmingStop = false },
            destructive = "刪除並關閉",
            onDestructive = {
                confirmingStop = false
                app.setTracing(false)
            },
        )
    }
}
