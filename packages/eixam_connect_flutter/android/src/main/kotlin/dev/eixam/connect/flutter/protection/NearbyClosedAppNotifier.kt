package dev.eixam.connect.flutter.protection

import android.app.Activity
import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import dev.eixam.connect.flutter.NotificationLaunchIntents
import org.json.JSONArray
import org.json.JSONObject

/**
 * Posts a user-visible nearby-chat notification when Dart is detached (app
 * swiped away / process dead). Flutter already handles the backgrounded-but-
 * alive case via [NearbyNotificationCoordinator].
 */
internal object NearbyClosedAppNotifier {
    // NotificationListenerService.Ranking.VISIBILITY_NO_OVERRIDE (not on public Notification API).
    private const val lockscreenVisibilityNoOverride = -1000

    private const val channelId = "eixam_nearby_messages"
    private const val notificationId = 43000
    private const val flutterPrefsName = "FlutterSharedPreferences"
    private const val mutedKey = "flutter.nearby.muted"
    private const val nicknamesKey = "flutter.nearby.nicknames"
    private const val hiddenKey = "flutter.nearby.hiddenNodeIds"

    fun maybeNotify(context: Context, payload: List<Int>) {
        val parsed = NearbyTextNotifyParser.tryParse(payload) ?: return
        HostUiVisibility.install(context)
        if (isHostAppForeground()) {
            return
        }
        val flutterPrefs =
            context.getSharedPreferences(flutterPrefsName, Context.MODE_PRIVATE)
        if (flutterPrefs.getBoolean(mutedKey, false)) {
            return
        }
        if (parsed.plaza && isHidden(flutterPrefs.getString(hiddenKey, null), parsed.fromNodeId)) {
            return
        }
        val runtimeStore = ProtectionRuntimeStore(context)
        if (!runtimeStore.rememberNearbyNotificationKey(parsed.dedupeKey)) {
            return
        }
        ensureChannel(context, runtimeStore)
        val title = senderLabel(
            nicknamesJson = flutterPrefs.getString(nicknamesKey, null),
            parsed = parsed,
            fallback = runtimeStore.nearbyMessageFallbackTitle(),
        )
        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(title)
            .setContentText(parsed.text)
            .setStyle(
                NotificationCompat.BigTextStyle()
                    .setBigContentTitle(title)
                    .bigText(parsed.text),
            )
            .setContentIntent(NotificationLaunchIntents.contentIntentForLaunchingApp(context))
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
        try {
            NotificationManagerCompat.from(context).notify(notificationId, notification)
        } catch (_: SecurityException) {
            // POST_NOTIFICATIONS denied. Nothing else to do from native.
        }
    }

    private fun isHostAppForeground(): Boolean {
        // A protection foreground service keeps this process "foreground" while
        // the UI is gone. Process importance is not "the user is looking".
        // No observed activity means the app is closed: still notify.
        if (!HostUiVisibility.hasObservedLifecycle) {
            return false
        }
        return HostUiVisibility.isResumed
    }

    private fun ensureChannel(context: Context, runtimeStore: ProtectionRuntimeStore) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val existing = manager.getNotificationChannel(channelId)
        if (existing != null && !channelCanAlertOnSecureLockScreen(existing)) {
            // Importance and lock-screen visibility are frozen after create.
            // A private/low channel hides the alert when secure lock is on.
            manager.deleteNotificationChannel(channelId)
        }
        val channel = NotificationChannel(
            channelId,
            runtimeStore.nearbyMessageChannelName(),
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = runtimeStore.nearbyMessageChannelDescription()
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        manager.createNotificationChannel(channel)
    }

    private fun channelCanAlertOnSecureLockScreen(channel: NotificationChannel): Boolean {
        if (channel.importance < NotificationManager.IMPORTANCE_HIGH) {
            return false
        }
        val visibility = channel.lockscreenVisibility
        return visibility == Notification.VISIBILITY_PUBLIC ||
            visibility == lockscreenVisibilityNoOverride
    }

    private fun senderLabel(
        nicknamesJson: String?,
        parsed: NearbyTextNotify,
        fallback: String,
    ): String {
        val nick = nicknameFor(nicknamesJson, parsed.fromNodeId)
        if (!nick.isNullOrBlank()) {
            return nick
        }
        return parsed.hardwareLabel.ifBlank { fallback }
    }

    private fun nicknameFor(raw: String?, nodeId: Int): String? {
        if (raw.isNullOrBlank()) {
            return null
        }
        return try {
            val decoded = JSONObject(raw)
            val unsigned = nodeId.toUInt().toString()
            decoded.optString(unsigned).trim().takeIf { it.isNotEmpty() }
                ?: decoded.optString(nodeId.toString()).trim().takeIf { it.isNotEmpty() }
        } catch (_: Exception) {
            null
        }
    }

    private fun isHidden(raw: String?, nodeId: Int): Boolean {
        if (raw.isNullOrBlank()) {
            return false
        }
        return try {
            val decoded = JSONArray(raw)
            val unsigned = nodeId.toUInt().toLong()
            for (index in 0 until decoded.length()) {
                if (decoded.optLong(index) == unsigned || decoded.optInt(index) == nodeId) {
                    return true
                }
            }
            false
        } catch (_: Exception) {
            false
        }
    }
}

/**
 * Counts resumed host activities. Protection mode's foreground service must
 * not be treated as "the user is looking at Nearby".
 */
internal object HostUiVisibility {
    @Volatile
    var resumedCount: Int = 0
        private set

    @Volatile
    var hasObservedLifecycle: Boolean = false
        private set

    @Volatile
    private var installed = false

    val isResumed: Boolean
        get() = resumedCount > 0

    fun install(context: Context) {
        if (installed) {
            return
        }
        val app = context.applicationContext as? Application ?: return
        installed = true
        app.registerActivityLifecycleCallbacks(
            object : Application.ActivityLifecycleCallbacks {
                override fun onActivityCreated(
                    activity: Activity,
                    savedInstanceState: Bundle?,
                ) {}

                override fun onActivityStarted(activity: Activity) {}

                override fun onActivityResumed(activity: Activity) {
                    hasObservedLifecycle = true
                    resumedCount++
                }

                override fun onActivityPaused(activity: Activity) {
                    hasObservedLifecycle = true
                    if (resumedCount > 0) {
                        resumedCount--
                    }
                }

                override fun onActivityStopped(activity: Activity) {
                    hasObservedLifecycle = true
                }

                override fun onActivitySaveInstanceState(
                    activity: Activity,
                    outState: Bundle,
                ) {}

                override fun onActivityDestroyed(activity: Activity) {
                    hasObservedLifecycle = true
                    resumedCount = 0
                }
            },
        )
    }
}
