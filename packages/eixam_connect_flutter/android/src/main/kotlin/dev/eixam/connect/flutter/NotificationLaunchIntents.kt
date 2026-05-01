package dev.eixam.connect.flutter

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Creates a [PendingIntent] that opens the host app's launcher activity (same as tapping the app icon).
 * Used for notification taps on SDK-owned foreground services.
 */
internal object NotificationLaunchIntents {
    fun contentIntentForLaunchingApp(context: Context): PendingIntent {
        val appContext = context.applicationContext
        val packageName = appContext.packageName
        val pm = appContext.packageManager
        val launchIntent =
            pm.getLaunchIntentForPackage(packageName)
                ?: Intent(Intent.ACTION_MAIN).apply {
                    addCategory(Intent.CATEGORY_LAUNCHER)
                    setPackage(packageName)
                }
        launchIntent.addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP,
        )
        return PendingIntent.getActivity(
            appContext,
            0,
            launchIntent,
            pendingIntentFlags(),
        )
    }

    private fun pendingIntentFlags(): Int {
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return flags
    }
}
