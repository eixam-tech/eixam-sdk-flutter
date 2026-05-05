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
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import dev.eixam.connect.flutter.NotificationLaunchIntents
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
    private val singleLocationListeners = mutableListOf<Pair<String, LocationListener>>()
    private var singleLocationTimeout: Runnable? = null
    private var sosLocationUpdatesActive = false

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
        reconcileSosLocationUpdates()
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
        cancelSingleLocationRequest(markTimeout = false)
        stopSosLocationUpdates()
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
        val mode = if (store.isSosOpen()) "sos" else "normal"
        Log.i(logTag, "$logPrefix tick mode=$mode reason=$reason")
        store.markPublishAttempt(reason)
        getBestEffortLocationForTick(locationTimeoutMs) { location, locationMode ->
            if (location == null) {
                val skipReason = when (locationMode) {
                    "timeout" -> "location_timeout"
                    "permission_missing" -> "location_permission_missing"
                    "provider_missing" -> "no_location_provider"
                    else -> "no_valid_location"
                }
                store.markError(skipReason)
                store.markLocationMode(locationMode)
                Log.i(
                    logTag,
                    "$logPrefix skip reason=$skipReason locationMode=$locationMode",
                )
                publishInFlight = false
                return@getBestEffortLocationForTick
            }
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
                    store.markPublishAttempt(reason, locationMode)
                    store.markPublished()
                    store.markHttpStatusCode(null)
                    Log.i(
                        logTag,
                        "$logPrefix publish result=success locationMode=$locationMode",
                    )
                } catch (error: Exception) {
                    val message = error.message ?: error.javaClass.simpleName
                    store.markError(message)
                    Log.w(logTag, "$logPrefix publish result=failed reason=$reason error=$message")
                } finally {
                    publishInFlight = false
                }
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
        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = 15000
            connection.readTimeout = 15000
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("X-App-ID", appId)
            connection.setRequestProperty("X-User-ID", externalUserId)
            connection.setRequestProperty("Authorization", "Bearer $userHash")
            val correlationId = nextCorrelationId("tel-http")
            Log.i(
                logTag,
                "[TELEMETRY_BACKEND_OUTBOUND_FINAL] transport=http " +
                    "endpoint=/v1/sdk/telemetry correlationId=$correlationId " +
                    "source=android_background_telemetry " +
                    "deviceId=${body.optStringOrNone("deviceId")} " +
                    "nodeId=${body.optStringOrNone("nodeId")} " +
                    "appDeviceId=${body.optStringOrNone("appDeviceId")} " +
                    "hardwareId=${body.optStringOrNone("hardwareId")} " +
                    "identitySource=${body.optStringOrNone("identitySource")} " +
                    "lat=${body.optStringOrNone("latitude")} " +
                    "lon=${body.optStringOrNone("longitude")} " +
                    "timestamp=${body.optStringOrNone("timestamp")} " +
                    "payload=${redactedCompactJson(body)}",
            )
            OutputStreamWriter(connection.outputStream, Charsets.UTF_8).use {
                it.write(body.toString())
            }
            val code = connection.responseCode
            store.markHttpStatusCode(code)
            if (code !in 200..299) {
                val errorBody = try {
                    connection.errorStream?.bufferedReader()?.use { it.readText() }
                } catch (_: Exception) {
                    null
                }
                Log.w(
                    logTag,
                    "$logPrefix publish result=failed httpStatus=$code body=${errorBody ?: "-"}",
                )
                Log.w(
                    logTag,
                    "[TELEMETRY_BACKEND_RESPONSE] correlationId=$correlationId " +
                        "status=$code responseSummary=${compactSummary(errorBody ?: "-")}",
                )
                throw IllegalStateException("http_$code")
            }
            Log.i(
                logTag,
                "[TELEMETRY_BACKEND_RESPONSE] correlationId=$correlationId " +
                    "status=$code responseSummary=ok",
            )
            Log.i(logTag, "$logPrefix publish httpStatus=$code")
        } finally {
            connection.disconnect()
        }
    }

    private fun isoNow(): String {
        val formatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        formatter.timeZone = TimeZone.getTimeZone("UTC")
        return formatter.format(Date())
    }

    private fun getBestEffortLocationForTick(
        timeoutMs: Long,
        onComplete: (Location?, String) -> Unit,
    ) {
        if (!hasLocationPermission()) {
            store.markError("location_permission_missing")
            onComplete(null, "permission_missing")
            return
        }
        val manager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val cached = freshestKnownLocation(manager)
        val maxAgeMs = if (store.isSosOpen()) sosCachedLocationMaxAgeMs else normalCachedLocationMaxAgeMs
        if (isValid(cached)) {
            val ageMs = locationAgeMs(cached!!)
            if (ageMs <= maxAgeMs) {
                lastLocation = cached
                store.markLocationMode("cached")
                Log.i(
                    logTag,
                    "$logPrefix location action=use_cached ageMs=$ageMs provider=${cached.provider}",
                )
                onComplete(cached, "cached")
                return
            }
        }
        if (store.isSosOpen() && sosLocationUpdatesActive) {
            store.markLocationMode("timeout")
            Log.i(logTag, "$logPrefix location action=timeout")
            onComplete(null, "timeout")
            return
        }
        requestSingleLocation(manager, timeoutMs, onComplete)
    }

    private fun requestSingleLocation(
        manager: LocationManager,
        timeoutMs: Long,
        onComplete: (Location?, String) -> Unit,
    ) {
        if (singleLocationListeners.isNotEmpty()) {
            Log.i(logTag, "$logPrefix location action=request_single_skipped reason=active")
            onComplete(null, "active")
            return
        }
        val providers = eligibleProviders(manager)
        if (providers.isEmpty()) {
            val fallback = relaxedNormalFallbackLocation(manager)
            if (fallback != null) {
                lastLocation = fallback
                store.markLocationMode("stale_fallback")
                Log.i(
                    logTag,
                    "$logPrefix location action=use_stale_fallback reason=no_provider " +
                        "ageMs=${locationAgeMs(fallback)} provider=${fallback.provider}",
                )
                onComplete(fallback, "stale_fallback")
                return
            }
            store.markError("no_location_provider")
            onComplete(null, "provider_missing")
            return
        }
        Log.i(
            logTag,
            "$logPrefix location action=request_single providers=${providers.joinToString(",")}",
        )
        store.markActiveLocationRequest(true)
        var completed = false
        fun complete(location: Location?, mode: String) {
            if (completed) {
                return
            }
            completed = true
            cancelSingleLocationRequest(markTimeout = mode == "timeout")
            onComplete(location, mode)
        }
        val timeout = Runnable {
            val fallback = relaxedNormalFallbackLocation(manager)
            if (fallback != null) {
                lastLocation = fallback
                Log.i(
                    logTag,
                    "$logPrefix location action=use_stale_fallback reason=timeout " +
                        "ageMs=${locationAgeMs(fallback)} provider=${fallback.provider}",
                )
                complete(fallback, "stale_fallback")
            } else {
                Log.i(logTag, "$logPrefix location action=timeout")
                complete(null, "timeout")
            }
        }
        singleLocationTimeout = timeout
        try {
            providers.forEach { provider ->
                val listener = object : LocationListener {
                    override fun onLocationChanged(location: Location) {
                        if (!isValid(location)) {
                            return
                        }
                        lastLocation = location
                        Log.i(
                            logTag,
                            "$logPrefix location action=received provider=${location.provider ?: provider}",
                        )
                        complete(location, "current:${location.provider ?: provider}")
                    }

                    @Deprecated("Deprecated Android platform callback")
                    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}

                    override fun onProviderDisabled(provider: String) {
                        Log.i(logTag, "$logPrefix location provider_disabled provider=$provider")
                    }
                }
                manager.requestLocationUpdates(provider, 0L, 0f, listener, Looper.getMainLooper())
                singleLocationListeners.add(provider to listener)
            }
            handler.postDelayed(timeout, timeoutMs)
        } catch (_: SecurityException) {
            cancelSingleLocationRequest(markTimeout = false)
            store.markError("location_permission_missing")
            onComplete(null, "permission_missing")
        } catch (_: IllegalArgumentException) {
            cancelSingleLocationRequest(markTimeout = false)
            store.markError("no_location_provider")
            onComplete(null, "provider_missing")
        }
    }

    private fun cancelSingleLocationRequest(markTimeout: Boolean) {
        val listeners = singleLocationListeners.toList()
        val timeout = singleLocationTimeout
        singleLocationListeners.clear()
        singleLocationTimeout = null
        if (timeout != null) {
            handler.removeCallbacks(timeout)
        }
        if (listeners.isNotEmpty()) {
            val manager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
            listeners.forEach { (provider, listener) ->
                try {
                    manager.removeUpdates(listener)
                } catch (_: SecurityException) {
                }
                Log.i(logTag, "$logPrefix location action=remove_single_update provider=$provider")
            }
            store.markActiveLocationRequest(false)
            if (markTimeout) {
                store.markLocationMode("timeout")
            }
        }
    }

    private fun reconcileSosLocationUpdates() {
        if (store.isSosOpen()) {
            startSosLocationUpdates()
        } else {
            stopSosLocationUpdates()
        }
    }

    private fun startSosLocationUpdates() {
        if (sosLocationUpdatesActive) {
            return
        }
        if (!hasLocationPermission()) {
            store.markError("location_permission_missing")
            return
        }
        val manager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val provider = bestProvider(manager) ?: run {
            store.markError("no_location_provider")
            return
        }
        try {
            manager.requestLocationUpdates(provider, sosIntervalMs, sosMovementThresholdMeters, this)
            sosLocationUpdatesActive = true
            Log.i(logTag, "$logPrefix location action=start_sos_updates intervalMs=$sosIntervalMs")
        } catch (_: SecurityException) {
            store.markError("location_permission_missing")
        } catch (_: IllegalArgumentException) {
            store.markError("no_location_provider")
        }
    }

    private fun stopSosLocationUpdates() {
        if (!sosLocationUpdatesActive) {
            return
        }
        val manager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        try {
            manager.removeUpdates(this)
        } catch (_: SecurityException) {
        }
        sosLocationUpdatesActive = false
        Log.i(logTag, "$logPrefix location action=remove_updates")
    }

    private fun freshestKnownLocation(manager: LocationManager): Location? {
        return (eligibleProviders(manager)
            .mapNotNull { provider ->
                try {
                    manager.getLastKnownLocation(provider)
                } catch (_: SecurityException) {
                    null
                } catch (_: IllegalArgumentException) {
                    null
                }
            }
            .plus(listOfNotNull(lastLocation)))
            .filter { isValid(it) }
            .minByOrNull { locationAgeMs(it) }
    }

    private fun freshestKnownLocationWithin(manager: LocationManager, maxAgeMs: Long): Location? {
        return freshestKnownLocation(manager)
            ?.takeIf { locationAgeMs(it) <= maxAgeMs }
    }

    private fun relaxedNormalFallbackLocation(manager: LocationManager): Location? {
        if (store.isSosOpen()) {
            return null
        }
        return freshestKnownLocationWithin(manager, normalStaleFallbackMaxAgeMs)
    }

    private fun bestProvider(manager: LocationManager): String? {
        val providers = eligibleProviders(manager)
        return when {
            providers.contains(LocationManager.NETWORK_PROVIDER) -> LocationManager.NETWORK_PROVIDER
            providers.contains(LocationManager.GPS_PROVIDER) -> LocationManager.GPS_PROVIDER
            else -> providers.firstOrNull()
        }
    }

    private fun eligibleProviders(manager: LocationManager): List<String> {
        val fine = hasFineLocationPermission()
        val coarse = hasCoarseLocationPermission()
        return manager.getProviders(true).filter { provider ->
            when (provider) {
                LocationManager.GPS_PROVIDER -> fine
                LocationManager.NETWORK_PROVIDER -> fine || coarse
                else -> fine
            }
        }
    }

    private fun locationAgeMs(location: Location): Long {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1) {
            ((SystemClock.elapsedRealtimeNanos() - location.elapsedRealtimeNanos) / 1_000_000L)
                .coerceAtLeast(0L)
        } else {
            (System.currentTimeMillis() - location.time).coerceAtLeast(0L)
        }
    }

    private fun hasLocationPermission(): Boolean {
        return hasFineLocationPermission() || hasCoarseLocationPermission()
    }

    private fun hasFineLocationPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun hasCoarseLocationPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
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
            .setContentIntent(NotificationLaunchIntents.contentIntentForLaunchingApp(this))
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

    private fun nextCorrelationId(prefix: String): String =
        "$prefix-${System.currentTimeMillis()}"

    private fun redactedCompactJson(payload: JSONObject): String {
        val copy = JSONObject(payload.toString())
        val userId = copy.optString("userId", "")
        if (userId.contains("@")) {
            copy.put("userId", "<redacted-email>")
        }
        listOf("token", "secret", "authorization", "password", "userHash", "email").forEach {
            if (copy.has(it)) {
                copy.put(it, "<redacted>")
            }
        }
        return copy.toString()
    }

    private fun compactSummary(value: String): String {
        val summary = value.replace(Regex("\\s+"), " ").trim()
        return if (summary.length <= 240) summary else summary.take(240) + "..."
    }

    private fun JSONObject.optStringOrNone(key: String): String =
        if (has(key) && !isNull(key)) optString(key).takeIf { it.isNotBlank() } ?: "none" else "none"

    private fun stopSelfSafely() {
        handler.removeCallbacks(tick)
        cancelSingleLocationRequest(markTimeout = false)
        stopSosLocationUpdates()
        store.markStopped()
        if (foregroundStarted) {
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            foregroundStarted = false
        }
        stopSelf()
    }

    companion object {
        private const val logTag = "EixamTelemetryService"
        private const val logPrefix = "[SDK_BG_TELEMETRY]"
        private const val notificationChannelId = "eixam_background_telemetry"
        private const val notificationId = 6031
        private const val defaultNotificationTitle = "EIXAM protection active"
        private const val defaultNotificationBody = "Sharing safety telemetry in the background"
        private const val actionStart = "dev.eixam.connect.flutter.action.TELEMETRY_START"
        private const val actionUpdate = "dev.eixam.connect.flutter.action.TELEMETRY_UPDATE"
        private const val actionStop = "dev.eixam.connect.flutter.action.TELEMETRY_STOP"
        private const val normalIntervalMs = 60000L
        private const val sosIntervalMs = 20000L
        private const val locationTimeoutMs = 8000L
        private const val normalCachedLocationMaxAgeMs = 45000L
        private const val sosCachedLocationMaxAgeMs = 15000L
        private const val normalStaleFallbackMaxAgeMs = 600000L
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
