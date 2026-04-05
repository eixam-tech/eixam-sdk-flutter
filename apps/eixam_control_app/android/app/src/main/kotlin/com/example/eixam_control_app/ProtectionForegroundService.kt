package com.example.eixam_control_app

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

class ProtectionForegroundService : Service() {
    private var bluetoothReceiver: BroadcastReceiver? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        registerBluetoothReceiver()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == actionStop) {
            ProtectionRuntimeBridge.markManualStopPending(applicationContext)
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }

        startForeground(notificationId, buildNotification())

        val wakeReason = intent?.getStringExtra(extraWakeReason)
        val wasActiveBeforeStart =
            ProtectionRuntimeBridge.isRuntimeMarkedActive(applicationContext)

        when {
            intent == null -> {
                ProtectionRuntimeBridge.markRuntimeRestarted(
                    applicationContext,
                    wakeReason ?: "system_restart",
                )
            }

            wasActiveBeforeStart -> {
                ProtectionRuntimeBridge.markRuntimeRecovered(
                    applicationContext,
                    wakeReason ?: "service_rebind",
                )
            }

            else -> {
                ProtectionRuntimeBridge.markRuntimeStarted(
                    applicationContext,
                    wakeReason ?: "explicit_start",
                )
            }
        }

        return START_STICKY
    }

    override fun onDestroy() {
        bluetoothReceiver?.let { unregisterReceiver(it) }
        bluetoothReceiver = null

        if (ProtectionRuntimeBridge.consumeManualStopPending(applicationContext)) {
            ProtectionRuntimeBridge.markRuntimeStopped(
                applicationContext,
                "explicit_stop",
            )
        }
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
                            ProtectionRuntimeBridge.markBluetoothState(
                                applicationContext,
                                true,
                            )

                        BluetoothAdapter.STATE_OFF ->
                            ProtectionRuntimeBridge.markBluetoothState(
                                applicationContext,
                                false,
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
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("EIXAM Protection Mode")
            .setContentText("Protection runtime is active and keeping Android recovery hooks armed.")
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
        private const val actionStart = "com.example.eixam_control_app.action.PROTECTION_START"
        private const val actionStop = "com.example.eixam_control_app.action.PROTECTION_STOP"
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
