package dev.eixam.connect.flutter.telemetry

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.concurrent.thread
import org.json.JSONObject

internal class EixamTelemetryForegroundService : Service(), LocationListener {
    private lateinit var store: BackgroundTelemetryStore
    private val handler = Handler(Looper.getMainLooper())
    private var publishInFlight = false
    private var foregroundStarted = false
    private var lastLocation: Location? = null
    private var lastPublishedSosLocation: Location? = null

    private val tick = object : Runnable {
        override fun run() {
            publishTelemetry("interval")
            scheduleNext()
        }
    }

    override fun onCreate() {
        super.onCreate()
        Log.i(logTag, "$logPrefix action=service_on_create")
        store = BackgroundTelemetryStore(applicationContext)
        ensureForegroundStarted(buildForegroundNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!foregroundStarted && !ensureForegroundStarted(buildForegroundNotification())) {
            return START_NOT_STICKY
        }
        if (intent?.action == actionStop) {
            stopSelfSafely()
            return START_NOT_STICKY
        }
        if (!hasLocationPermission()) {
            store.markError("location_permission_missing")
            logStop("missing_permission")
            stopSelfSafely()
            return START_NOT_STICKY
        }
        if (!hasRequiredTelemetryConfig()) {
            store.markError("missing_session_or_backend_config")
            logStop("missing_config")
            stopSelfSafely()
            return START_NOT_STICKY
        }
        if (!updateForegroundNotification()) {
            return START_NOT_STICKY
        }
        store.markServiceRunning(true)
        startLocationUpdates()
        if (intent?.action == actionUpdate) {
            scheduleNext()
            return START_STICKY
        }
        publishTelemetry("service_start")
        scheduleNext()
        return START_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(tick)
        stopLocationUpdates()
        store.markServiceRunning(false)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onLocationChanged(location: Location) {
        if (!isValid(location)) {
            return
        }
        lastLocation = location
        if (!store.isSosOpen()) {
            return
        }
        val anchor = lastPublishedSosLocation ?: run {
            lastPublishedSosLocation = location
            return
        }
        if (anchor.distanceTo(location) >= sosMovementThresholdMeters) {
            publishTelemetry("sos_moved")
        }
    }

    @Deprecated("Deprecated Android platform callback")
    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}

    private fun scheduleNext() {
        handler.removeCallbacks(tick)
        if (!store.isEnabled()) {
            return
        }
        val delay = if (store.isSosOpen()) sosIntervalMs else normalIntervalMs
        handler.postDelayed(tick, delay)
    }

    private fun publishTelemetry(reason: String) {
        if (publishInFlight || !store.isEnabled()) {
            return
        }
        val location = latestValidLocation()
        if (location == null) {
            store.markError("no_valid_location")
            return
        }
        val apiBaseUrl = store.apiBaseUrl()?.trim()
        val appId = store.appId()?.trim()
        val externalUserId = store.externalUserId()?.trim()
        val userHash = store.userHash()?.trim()
        if (apiBaseUrl.isNullOrEmpty() || appId.isNullOrEmpty() ||
            externalUserId.isNullOrEmpty() || userHash.isNullOrEmpty()
        ) {
            store.markError("missing_session_or_backend_config")
            return
        }
        publishInFlight = true
        thread(name = "eixam-bg-telemetry") {
            try {
                postTelemetry(
                    apiBaseUrl = apiBaseUrl,
                    appId = appId,
                    externalUserId = externalUserId,
                    userHash = userHash,
                    body = buildPayload(location),
                )
                if (store.isSosOpen()) {
                    lastPublishedSosLocation = location
                }
                store.markPublished()
            } catch (error: Exception) {
                store.markError("${reason}: ${error.message ?: error.javaClass.simpleName}")
            } finally {
                publishInFlight = false
            }
        }
    }

    private fun buildPayload(location: Location): JSONObject {
        val payload = JSONObject()
            .put("timestamp", isoNow())
            .put("latitude", location.latitude)
            .put("longitude", location.longitude)
            .put("altitude", location.altitude)
        val userId = store.canonicalExternalUserId()?.takeIf { it.isNotBlank() }
            ?: store.externalUserId()
        if (!userId.isNullOrBlank()) {
            payload.put("userId", userId)
        }
        store.deviceId()?.takeIf { it.isNotBlank() }?.let {
            payload.put("deviceId", it)
        }
        store.deviceBatteryJson()?.let {
            payload.put("deviceBattery", JSONObject(it))
        }
        store.deviceCoverageJson()?.let {
            payload.put("deviceCoverage", JSONObject(it))
        }
        return payload
    }

    private fun postTelemetry(
        apiBaseUrl: String,
        appId: String,
        externalUserId: String,
        userHash: String,
        body: JSONObject,
    ) {
        val base = apiBaseUrl.trimEnd('/')
        val connection = URL("$base/v1/sdk/telemetry").openConnection() as HttpURLConnection
        connection.requestMethod = "POST"
        connection.connectTimeout = 15000
        connection.readTimeout = 15000
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/json")
        connection.setRequestProperty("Accept", "application/json")
        connection.setRequestProperty("X-App-ID", appId)
        connection.setRequestProperty("X-User-ID", externalUserId)
        connection.setRequestProperty("Authorization", "Bearer $userHash")
        OutputStreamWriter(connection.outputStream, Charsets.UTF_8).use {
            it.write(body.toString())
        }
        val code = connection.responseCode
        if (code !in 200..299) {
            throw IllegalStateException("http_$code")
        }
        connection.disconnect()
    }

    private fun isoNow(): String {
        val formatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        formatter.timeZone = TimeZone.getTimeZone("UTC")
        return formatter.format(Date())
    }

    private fun latestValidLocation(): Location? {
        val current = lastLocation
        if (isValid(current)) {
            return current
        }
        if (!hasLocationPermission()) {
            return null
        }
        val manager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        return manager.getProviders(true)
            .mapNotNull { provider ->
                try {
                    manager.getLastKnownLocation(provider)
                } catch (_: SecurityException) {
                    null
                }
            }
            .firstOrNull { isValid(it) }
            ?.also { lastLocation = it }
    }

    private fun startLocationUpdates() {
        if (!hasLocationPermission()) {
            store.markError("location_permission_missing")
            return
        }
        val manager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        for (provider in manager.getProviders(true)) {
            try {
                manager.requestLocationUpdates(provider, 10000L, 3f, this)
            } catch (_: SecurityException) {
                store.markError("location_permission_missing")
            } catch (_: IllegalArgumentException) {
                // Provider disappeared; another provider may still work.
            }
        }
    }

    private fun stopLocationUpdates() {
        val manager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        try {
            manager.removeUpdates(this)
        } catch (_: SecurityException) {
        }
    }

    private fun hasLocationPermission(): Boolean {
        val fine = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        val coarse = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        return fine || coarse
    }

    private fun isValid(location: Location?): Boolean {
        if (location == null) {
            return false
        }
        return location.latitude in -90.0..90.0 &&
            location.longitude in -180.0..180.0
    }

    private fun buildNotification(): Notification {
        return buildForegroundNotification(
            title = store.notificationTitle() ?: defaultNotificationTitle,
            body = store.notificationBody() ?: defaultNotificationBody,
        )
    }

    private fun buildForegroundNotification(
        title: String = defaultNotificationTitle,
        body: String = defaultNotificationBody,
    ): Notification {
        return NotificationCompat.Builder(this, notificationChannelId)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle(title)
            .setContentText(body)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun ensureForegroundStarted(notification: Notification): Boolean {
        if (foregroundStarted) {
            return true
        }
        return try {
            ensureNotificationChannel()
            ServiceCompat.startForeground(
                this,
                notificationId,
                notification,
                foregroundServiceType(),
            )
            foregroundStarted = true
            Log.i(logTag, "$logPrefix action=foreground_started")
            true
        } catch (error: SecurityException) {
            store.markError("foreground_start_failed: ${error.message ?: error.javaClass.simpleName}")
            Log.e(
                logTag,
                "$logPrefix action=foreground_start_failed error=${error.message ?: error.javaClass.simpleName}",
            )
            store.markStopped()
            stopSelf()
            false
        } catch (error: Exception) {
            store.markError("foreground_start_failed: ${error.message ?: error.javaClass.simpleName}")
            Log.e(
                logTag,
                "$logPrefix action=foreground_start_failed error=${error.message ?: error.javaClass.simpleName}",
            )
            store.markStopped()
            stopSelf()
            false
        }
    }

    private fun updateForegroundNotification(): Boolean {
        if (!foregroundStarted) {
            return false
        }
        return try {
            ServiceCompat.startForeground(
                this,
                notificationId,
                buildNotification(),
                foregroundServiceType(),
            )
            true
        } catch (error: SecurityException) {
            store.markError("foreground_update_failed: ${error.message ?: error.javaClass.simpleName}")
            logStop("missing_permission")
            stopSelfSafely()
            false
        } catch (error: Exception) {
            store.markError("foreground_update_failed: ${error.message ?: error.javaClass.simpleName}")
            logStop("foreground_update_failed")
            stopSelfSafely()
            false
        }
    }

    private fun foregroundServiceType(): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return 0
        }
        return android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val channel = NotificationChannel(
            notificationChannelId,
            "EIXAM background telemetry",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Keeps SDK safety telemetry active while the app is backgrounded."
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun hasRequiredTelemetryConfig(): Boolean {
        val apiBaseUrl = store.apiBaseUrl()?.trim()
        val appId = store.appId()?.trim()
        val externalUserId = store.externalUserId()?.trim()
        val userHash = store.userHash()?.trim()
        return !apiBaseUrl.isNullOrEmpty() &&
            !appId.isNullOrEmpty() &&
            !externalUserId.isNullOrEmpty() &&
            !userHash.isNullOrEmpty()
    }

    private fun logStop(reason: String) {
        Log.i(logTag, "$logPrefix action=stop reason=$reason")
    }

    private fun stopSelfSafely() {
        handler.removeCallbacks(tick)
        stopLocationUpdates()
        store.markStopped()
        if (foregroundStarted) {
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            foregroundStarted = false
        }
        stopSelf()
    }

    companion object {
        private const val logTag = "EixamTelemetryService"
        private const val logPrefix = "[SDK_TELEMETRY_BACKGROUND]"
        private const val notificationChannelId = "eixam_background_telemetry"
        private const val notificationId = 6031
        private const val defaultNotificationTitle = "EIXAM protection active"
        private const val defaultNotificationBody = "Sharing safety telemetry in the background"
        private const val actionStart = "dev.eixam.connect.flutter.action.TELEMETRY_START"
        private const val actionUpdate = "dev.eixam.connect.flutter.action.TELEMETRY_UPDATE"
        private const val actionStop = "dev.eixam.connect.flutter.action.TELEMETRY_STOP"
        private const val normalIntervalMs = 60000L
        private const val sosIntervalMs = 20000L
        private const val sosMovementThresholdMeters = 7f

        fun start(context: Context) {
            val intent = Intent(context, EixamTelemetryForegroundService::class.java).apply {
                action = actionStart
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun update(context: Context) {
            val intent = Intent(context, EixamTelemetryForegroundService::class.java).apply {
                action = actionUpdate
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, EixamTelemetryForegroundService::class.java).apply {
                action = actionStop
            }
            context.startService(intent)
        }
    }
}
