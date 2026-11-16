package com.follow.clash.common

import android.app.ActivityManager
import android.app.Application
import android.os.Build
import android.util.Log
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

object GlobalState : CoroutineScope by CoroutineScope(SupervisorJob() + Dispatchers.Default) {
    const val NOTIFICATION_CHANNEL = "FlClash"
    const val NOTIFICATION_ID = 1
    private const val ANY_PID = 0
    private const val EVERY_EXIT_RECORD = 0
    private const val LOG_TAG = "FlClash"

    val packageName: String
        get() = application.packageName

    val receiveBroadcastPermission: String
        get() = "$packageName.permission.RECEIVE_BROADCASTS"

    val application: Application
        get() = checkNotNull(appInstance) { "GlobalState is not initialized" }

    @Volatile
    private var appInstance: Application? = null
    private val logSink = AtomicReference<((String) -> Unit)?>(null)

    fun init(application: Application) {
        appInstance = application
    }

    // The exported log is the Core's event stream collected by Dart, so a
    // line that stops at logcat never reaches the file worth reading.
    fun setLogSink(sink: ((String) -> Unit)?) {
        logSink.set(sink)
    }

    fun log(text: String) {
        Log.d(LOG_TAG, text)
        logSink.get()?.invoke(text)
    }

    fun lastExitInfo(): Map<String, Any?>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        val manager = application.getSystemService(ActivityManager::class.java) ?: return null
        val info = runCatching {
            manager.getHistoricalProcessExitReasons(
                application.packageName,
                ANY_PID,
                EVERY_EXIT_RECORD,
            )
        }.getOrNull()?.firstOrNull { it.processName == application.packageName } ?: return null
        return mapOf(
            "reason" to info.reason,
            "timestamp" to info.timestamp,
            "description" to info.description,
        )
    }
}
