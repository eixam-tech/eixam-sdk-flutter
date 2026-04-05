package dev.eixam.connect.flutter.protection

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

internal class ProtectionForegroundService : Service() {
    private var bluetoothReceiver: BroadcastReceiver? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        registerBluetoothReceiver()
        ProtectionRuntimeBridge.recordPlatformEvent(
            context = applicationContext,
            type = "serviceStarted",
            reason = "foreground_service_created",
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == actionStop) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }

        startForeground(notificationId, buildNotification())
        ProtectionRuntimeBridge.recordPlatformEvent(
            context = applicationContext,
            type = if (intent == null) "serviceRestarted" else "runtimeStarted",
            reason = intent?.getStringExtra(extraWakeReason) ?: "service_start",
        )
        return START_STICKY
    }

    override fun onDestroy() {
        bluetoothReceiver?.let { unregisterReceiver(it) }
        bluetoothReceiver = null
        ProtectionRuntimeBridge.recordPlatformEvent(
            context = applicationContext,
            type = "serviceStopped",
            reason = "foreground_service_destroyed",
        )
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun registerBluetoothReceiver() {
        val receiver =
            object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) {
                        return
                    }
                    when (
                        intent.getIntExtra(
                            BluetoothAdapter.EXTRA_STATE,
                            BluetoothAdapter.ERROR,
                        )
                    ) {
                        BluetoothAdapter.STATE_ON ->
                            ProtectionRuntimeBridge.recordPlatformEvent(
                                context = applicationContext,
                                type = "bluetoothTurnedOn",
                                reason = "bluetooth_on",
                            )

                        BluetoothAdapter.STATE_OFF ->
                            ProtectionRuntimeBridge.recordPlatformEvent(
                                context = applicationContext,
                                type = "bluetoothTurnedOff",
                                reason = "bluetooth_off",
                            )
                    }
                }
            }

        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(receiver, filter)
        }
        bluetoothReceiver = receiver
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, notificationChannelId)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("EIXAM Protection Mode")
            .setContentText(
                "Protection Mode is armed. The Android foreground service owns the runtime while coverage is active.",
            )
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }

        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            notificationChannelId,
            "Protection Mode Runtime",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Keeps the Android Protection Mode runtime visible and restartable."
        }
        manager.createNotificationChannel(channel)
    }

    companion object {
        private const val notificationChannelId = "eixam_protection_runtime"
        private const val notificationId = 6021
        private const val actionStart = "dev.eixam.connect.flutter.action.PROTECTION_START"
        private const val actionStop = "dev.eixam.connect.flutter.action.PROTECTION_STOP"
        private const val extraWakeReason = "wake_reason"

        fun start(context: Context) {
            val intent = Intent(context, ProtectionForegroundService::class.java).apply {
                action = actionStart
                putExtra(extraWakeReason, "enter_protection_mode")
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, ProtectionForegroundService::class.java).apply {
                action = actionStop
            }
            context.startService(intent)
        }
    }
}
