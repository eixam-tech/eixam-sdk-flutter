package dev.eixam.connect.flutter.protection

import android.app.Activity
import android.app.KeyguardManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import dev.eixam.connect.flutter.NotificationLaunchIntents

/**
 * F17c ambiguous TAG SOS prompt: the notification's two actions. Pure data so
 * the JVM unit tests can check the contract (Owner decision 16/11/2026: a
 * normal local notification, no full-screen intent, no time-sensitive level).
 */
internal object ProtectionSosPromptSpec {
    const val actionSendSos = "dev.eixam.connect.flutter.action.SOS_PROMPT_SEND"
    const val actionStopTag = "dev.eixam.connect.flutter.action.SOS_PROMPT_STOP"
    const val notificationId = 6026
    const val stoppedNotificationId = 6027

    /** Owner decision: never a full-screen intent (no USE_FULL_SCREEN_INTENT). */
    const val usesFullScreenIntent = false

    data class Action(
        val intentAction: String,
        val choice: String,
        /** Lock screen: needs the device unlocked before it runs. */
        val requiresUnlock: Boolean,
        /** Delivered to an activity (an activity launch from the lock screen needs an unlock). */
        val opensActivity: Boolean,
    )

    /** "Send SOS" first (primary): one tap, no unlock. "No, stop the TAG": unlock required. */
    val actions: List<Action> = listOf(
        Action(actionSendSos, choice = "sendSos", requiresUnlock = false, opensActivity = false),
        Action(actionStopTag, choice = "stopTag", requiresUnlock = true, opensActivity = true),
    )

    fun choiceFor(intentAction: String?): String? =
        actions.firstOrNull { it.intentAction == intentAction }?.choice

    /** `Notification.Action.setAuthenticationRequired` exists from API 31. */
    fun authenticationRequiredSupported(sdkInt: Int): Boolean = sdkInt >= 31

    /** Text of the notification body, the 30 s countdown is in the approved copy. */
    fun remainingSeconds(deadlineAt: Long, now: Long): Long =
        ((deadlineAt - now + 999L) / 1000L).coerceIn(0L, ProtectionSosStaleGuard.promptMs / 1000L)
}

internal object ProtectionSosPromptNotifications {
    private const val logTag = "EixamSosPrompt"
    private const val sosNotificationChannelId = "eixam_protection_sos"

    fun show(context: Context, deadlineAt: Long) {
        val appContext = context.applicationContext
        val store = ProtectionRuntimeStore(appContext)
        ensureChannel(appContext, store)
        val builder = NotificationCompat.Builder(appContext, sosNotificationChannelId)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setContentTitle(store.protectionSosAmbiguousTitle())
            .setContentText(store.protectionSosAmbiguousBody())
            .setStyle(NotificationCompat.BigTextStyle().bigText(store.protectionSosAmbiguousBody()))
            .setContentIntent(NotificationLaunchIntents.contentIntentForLaunchingApp(appContext))
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            // Live countdown to the automatic SOS.
            .setWhen(deadlineAt)
            .setShowWhen(true)
            .setUsesChronometer(true)
            .setChronometerCountDown(true)
        for (action in ProtectionSosPromptSpec.actions) {
            val label = if (action.choice == "sendSos") {
                store.protectionSosAmbiguousSendAction()
            } else {
                store.protectionSosAmbiguousStopAction()
            }
            val actionBuilder = NotificationCompat.Action.Builder(0, label, pendingIntent(appContext, action))
            if (action.requiresUnlock &&
                ProtectionSosPromptSpec.authenticationRequiredSupported(Build.VERSION.SDK_INT)
            ) {
                actionBuilder.setAuthenticationRequired(true)
            }
            builder.addAction(actionBuilder.build())
        }
        // Owner decision: no setFullScreenIntent (ProtectionSosPromptSpec.usesFullScreenIntent).
        try {
            NotificationManagerCompat.from(appContext).notify(ProtectionSosPromptSpec.notificationId, builder.build())
            Log.i(logTag, "SOS_PROMPT_NOTIFICATION_POSTED")
        } catch (error: SecurityException) {
            // No notification permission: the native timeout still sends the SOS.
            Log.w(logTag, "SOS_PROMPT_NOTIFICATION_SKIPPED reason=permission")
        }
    }

    fun cancel(context: Context) {
        NotificationManagerCompat.from(context.applicationContext).cancel(ProtectionSosPromptSpec.notificationId)
    }

    /** After "No": "TAG stopped. No SOS was sent." */
    fun showStopped(context: Context) {
        val appContext = context.applicationContext
        val store = ProtectionRuntimeStore(appContext)
        ensureChannel(appContext, store)
        val notification = NotificationCompat.Builder(appContext, sosNotificationChannelId)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle(store.protectionSosAmbiguousStoppedBody())
            .setContentIntent(NotificationLaunchIntents.contentIntentForLaunchingApp(appContext))
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()
        try {
            NotificationManagerCompat.from(appContext).notify(ProtectionSosPromptSpec.stoppedNotificationId, notification)
        } catch (error: SecurityException) {
            Log.w(logTag, "SOS_PROMPT_STOPPED_NOTIFICATION_SKIPPED reason=permission")
        }
    }

    private fun pendingIntent(context: Context, action: ProtectionSosPromptSpec.Action): PendingIntent {
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        val requestCode = if (action.choice == "sendSos") 6026 else 6027
        return if (action.opensActivity) {
            val intent = Intent(context, ProtectionSosPromptStopActivity::class.java)
                .setAction(action.intentAction)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_HISTORY)
            PendingIntent.getActivity(context, requestCode, intent, flags)
        } else {
            val intent = Intent(context, ProtectionSosPromptActionReceiver::class.java)
                .setAction(action.intentAction)
            PendingIntent.getBroadcast(context, requestCode, intent, flags)
        }
    }

    /** The SOS channel exists even when the Protection service never ran (Dart owns the link). */
    private fun ensureChannel(context: Context, store: ProtectionRuntimeStore) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(sosNotificationChannelId) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                sosNotificationChannelId,
                store.protectionSosChannelName(),
                NotificationManager.IMPORTANCE_HIGH,
            ).apply { description = store.protectionSosChannelDescription() },
        )
    }
}

/** "Send SOS": one tap, works from the lock screen, no unlock, no app launch. */
internal class ProtectionSosPromptActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val choice = ProtectionSosPromptSpec.choiceFor(intent.action) ?: return
        if (choice != "sendSos") return
        val pending = goAsync()
        try {
            ProtectionRuntimeBridge.ensureRuntimeOwner(context.applicationContext)
                .answerOwnTagSosPrompt(choice, source = "notification")
        } finally {
            pending.finish()
        }
    }
}

/**
 * "No, stop the TAG": an activity, so the lock screen asks for the unlock
 * before it runs (and on API 31+ the action itself requires authentication).
 * It shows nothing and finishes at once.
 */
internal class ProtectionSosPromptStopActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val choice = ProtectionSosPromptSpec.choiceFor(intent?.action)
        if (choice != "stopTag") {
            finish()
            return
        }
        val keyguard = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        if (keyguard?.isKeyguardLocked == true) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                keyguard.requestDismissKeyguard(
                    this,
                    object : KeyguardManager.KeyguardDismissCallback() {
                        override fun onDismissSucceeded() = answerAndFinish()
                        override fun onDismissCancelled() = finish()
                        override fun onDismissError() = finish()
                    },
                )
            } else {
                // Never a stop without an unlock: the timeout applies.
                finish()
            }
            return
        }
        answerAndFinish()
    }

    private fun answerAndFinish() {
        ProtectionRuntimeBridge.ensureRuntimeOwner(applicationContext)
            .answerOwnTagSosPrompt("stopTag", source = "notification")
        finish()
    }
}
