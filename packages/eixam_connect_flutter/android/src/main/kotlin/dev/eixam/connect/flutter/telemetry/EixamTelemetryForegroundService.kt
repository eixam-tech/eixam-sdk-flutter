package dev.eixam.connect.flutter.telemetry

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
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
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt
import org.json.JSONObject

internal class EixamTelemetryForegroundService : Service(), LocationListener {
    private lateinit var store: BackgroundTelemetryStore
    private lateinit var flutterPreferences: android.content.SharedPreferences
    private val handler = Handler(Looper.getMainLooper())
    private var publishInFlight = false
    private var foregroundStarted = false
    private var lastLocation: Location? = null
    private var lastPublishedSosLocation: Location? = null
    private var lastDebugAcceptedLocation: Location? = null
    private var lastDebugAcceptedSource: String? = null
    private var lastRestBlockedLogAtMs = 0L
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
        store = BackgroundTelemetryStore(applicationContext)
        flutterPreferences = applicationContext.getSharedPreferences(
            flutterPrefsName,
            Context.MODE_PRIVATE,
        )
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
        store.markPublishAttempt(reason)
        if (shouldBlockRestTelemetry()) {
            logTelemetryRestBlocked(reason)
            store.markHttpStatusCode(null)
            queueTelemetryForMqtt(reason)
            return
        }
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
                publishInFlight = false
                return@getBestEffortLocationForTick
            }
            thread(name = "eixam-bg-telemetry") {
                try {
                    val body = buildPayload(location, reason = reason)
                    logLocationAuth(
                        flow = "native_foreground_final",
                        source = locationMode,
                        location = location,
                        accepted = true,
                        sentToBackend = true,
                    )
                    postTelemetry(
                        apiBaseUrl = apiBaseUrl,
                        appId = appId,
                        externalUserId = externalUserId,
                        userHash = userHash,
                        body = body,
                    )
                    if (store.isSosOpen()) {
                        lastPublishedSosLocation = location
                    }
                    store.markPublishAttempt(reason, locationMode)
                    store.markPublished()
                    store.markHttpStatusCode(null)
                } catch (error: Exception) {
                    val message = error.message ?: error.javaClass.simpleName
                    store.markError(message)
                } finally {
                    publishInFlight = false
                }
            }
        }
    }

    private fun queueTelemetryForMqtt(reason: String) {
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
                publishInFlight = false
                return@getBestEffortLocationForTick
            }
            thread(name = "eixam-bg-telemetry-queue") {
                try {
                    val body = buildPayload(location, reason = reason)
                    logLocationAuth(
                        flow = "native_foreground_final",
                        source = locationMode,
                        location = location,
                        accepted = true,
                        sentToBackend = false,
                    )
                    val queued = store.queueTelemetry(
                        payload = body,
                        reason = reason,
                        locationMode = locationMode,
                        sosContext = store.isSosOpen(),
                    )
                    if (queued.duplicate) {
                        Log.i(
                            logTag,
                            "TELEMETRY_NATIVE_DUPLICATE_SUPPRESSED " +
                                "handoffId=${queued.signature} queueSize=${queued.queueSize}",
                        )
                    } else {
                        Log.i(
                            logTag,
                            "TELEMETRY_NATIVE_QUEUED " +
                                "handoffId=${queued.signature} queueSize=${queued.queueSize}",
                        )
                        if (queued.droppedOldest) {
                            Log.w(
                                logTag,
                                "TELEMETRY_NATIVE_QUEUE_DROPPED_OLDEST " +
                                    "queueSize=${queued.queueSize}",
                            )
                        }
                    }
                } catch (error: Exception) {
                    store.markError(error.message ?: error.javaClass.simpleName)
                } finally {
                    publishInFlight = false
                }
            }
        }
    }

    private fun buildPayload(location: Location, reason: String): JSONObject {
        val timestamp = isoNow()
        val deviceId = store.deviceId()?.takeIf { it.isNotBlank() && !looksLikeBleMac(it) }
        val payload = JSONObject()
            .put("timestamp", timestamp)
            .put("latitude", location.latitude)
            .put("longitude", location.longitude)
            .put("altitude", location.altitude)
            .put("eventId", nativeTelemetryEventId(timestamp, deviceId, reason))
            .put("kind", "background")
            .put("identitySource", "native_background")
        deviceId?.let {
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

    private fun nativeTelemetryEventId(
        timestamp: String,
        deviceId: String?,
        reason: String,
    ): String =
        listOf(
            "native-bg",
            timestamp.replace(Regex("[^A-Za-z0-9]"), ""),
            deviceId?.replace(Regex("[^A-Za-z0-9_.-]"), "-") ?: "phone",
            reason.replace(Regex("[^A-Za-z0-9_.-]"), "-"),
        ).joinToString("-")

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
                throw IllegalStateException("http_$code")
            }
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
        val resolvedTelemetryLocation = loadResolvedTelemetryLocation()
        if (resolvedTelemetryLocation != null) {
            val (resolvedLocation, resolvedSource) = resolvedTelemetryLocation
            val resolvedMode = when (resolvedSource) {
                "phone" -> "sdk_resolved_phone"
                else -> "sdk_resolved_connected_device"
            }
            lastLocation = resolvedLocation
            store.markLocationMode(resolvedMode)
            logLocationAuth(
                flow = "native_foreground_candidate",
                source = resolvedSource,
                location = resolvedLocation,
                accepted = true,
                persisted = true,
            )
            onComplete(resolvedLocation, resolvedMode)
            return
        }
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
                logLocationAuth(
                    flow = "native_foreground_candidate",
                    source = "phone_cached_os",
                    location = cached,
                    accepted = true,
                    persisted = true,
                )
                onComplete(cached, "cached")
                return
            }
            logLocationAuth(
                flow = "native_foreground_candidate",
                source = "phone_cached_os",
                location = cached,
                accepted = false,
                rejectionReason = "stale_cached_os_location",
                persisted = true,
            )
        }
        if (store.isSosOpen() && sosLocationUpdatesActive) {
            store.markLocationMode("timeout")
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
            onComplete(null, "active")
            return
        }
        val providers = eligibleProviders(manager)
        if (providers.isEmpty()) {
            store.markError("no_location_provider")
            onComplete(null, "provider_missing")
            return
        }
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
            complete(null, "timeout")
        }
        singleLocationTimeout = timeout
        try {
            providers.forEach { provider ->
                val listener = object : LocationListener {
                    override fun onLocationChanged(location: Location) {
                        if (!isValid(location)) {
                            logLocationAuth(
                                flow = "native_foreground_candidate",
                                source = "phone_current:${location.provider ?: provider}",
                                location = location,
                                accepted = false,
                                rejectionReason = "invalid_current_location",
                            )
                            return
                        }
                        lastLocation = location
                        logLocationAuth(
                            flow = "native_foreground_candidate",
                            source = "phone_current:${location.provider ?: provider}",
                            location = location,
                            accepted = true,
                        )
                        complete(location, "current:${location.provider ?: provider}")
                    }

                    @Deprecated("Deprecated Android platform callback")
                    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}

                    override fun onProviderDisabled(provider: String) {
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
            location.longitude in -180.0..180.0 &&
            !(location.latitude == 0.0 && location.longitude == 0.0)
    }

    private fun loadResolvedTelemetryLocation(): Pair<Location, String>? {
        val raw =
            flutterPreferences.getString("$flutterKeyPrefix${resolvedLocationKey}", null)
                ?: return null
        val json = JSONObject(raw)
        val source = json.optString("source", "unknown")
        if (
            json.optInt(resolvedLocationHandoffVersionKey, 0) != resolvedLocationHandoffVersion ||
            json.optString(geoDecoderVersionKey, "") != expectedGeoDecoderVersion
        ) {
            logLocationAuthRaw(
                flow = "native_foreground_candidate",
                source = source,
                latitude = if (json.has("latitude") && !json.isNull("latitude")) json.optDouble("latitude") else null,
                longitude = if (json.has("longitude") && !json.isNull("longitude")) json.optDouble("longitude") else null,
                timestamp = json.optString("timestamp", "").takeIf { it.isNotBlank() },
                accepted = false,
                rejectionReason = "stale_or_incompatible_decoder_version",
                authoritativeForBackend = json.optBoolean("authoritativeForBackend", false),
                persisted = true,
            )
            flutterPreferences.edit()
                .remove("$flutterKeyPrefix${resolvedLocationKey}")
                .apply()
            return null
        }
        if (!json.optBoolean("authoritativeForBackend", false)) {
            logLocationAuthRaw(
                flow = "native_foreground_candidate",
                source = source,
                accepted = false,
                rejectionReason = "persisted_resolved_not_authoritative",
                persisted = true,
            )
            return null
        }
        if (source != "connectedDevice" && source != "phone") {
            logLocationAuthRaw(
                flow = "native_foreground_candidate",
                source = source,
                accepted = false,
                rejectionReason = "persisted_resolved_source_not_allowed",
                authoritativeForBackend = true,
                persisted = true,
            )
            return null
        }
        if (!json.has("latitude") || json.isNull("latitude") ||
            !json.has("longitude") || json.isNull("longitude") ||
            !json.has("timestamp") || json.isNull("timestamp")
        ) {
            logLocationAuthRaw(
                flow = "native_foreground_candidate",
                source = source,
                accepted = false,
                rejectionReason = "persisted_resolved_missing_coordinate",
                authoritativeForBackend = true,
                persisted = true,
            )
            return null
        }
        val timestamp = json.getString("timestamp")
        val sampleAgeMs = resolvedLocationAgeMs(timestamp)
        val persistedAt = json.optString("persistedAt", "")
            .takeIf { it.isNotBlank() }
            ?: json.optString("updatedAt", "").takeIf { it.isNotBlank() }
        val persistedAgeMs = persistedAt?.let { resolvedLocationAgeMs(it) }
        if (sampleAgeMs > resolvedLocationMaxAgeMs ||
            (persistedAgeMs != null && persistedAgeMs > resolvedLocationMaxAgeMs)
        ) {
            logLocationAuthRaw(
                flow = "native_foreground_candidate",
                source = source,
                latitude = json.optDouble("latitude"),
                longitude = json.optDouble("longitude"),
                timestamp = timestamp,
                accepted = false,
                rejectionReason = "stale_sdk_resolved_location",
                authoritativeForBackend = true,
                persisted = true,
            )
            return null
        }
        val location = Location("eixam_resolved_$source")
        location.latitude = json.getDouble("latitude")
        location.longitude = json.getDouble("longitude")
        if (!json.isNull("altitudeMeters")) {
            location.altitude = json.optDouble("altitudeMeters")
        }
        location.time = resolvedLocationEpochMs(timestamp) ?: System.currentTimeMillis()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1) {
            location.elapsedRealtimeNanos = (
                SystemClock.elapsedRealtimeNanos() -
                    sampleAgeMs.coerceAtLeast(0L) * 1_000_000L
                ).coerceAtLeast(0L)
        }
        return if (isValid(location) &&
            !(location.latitude == 0.0 && location.longitude == 0.0)
        ) {
            location to source
        } else {
            logLocationAuth(
                flow = "native_foreground_candidate",
                source = source,
                location = location,
                accepted = false,
                rejectionReason = "persisted_resolved_invalid_coordinate",
                persisted = true,
            )
            null
        }
    }

    private fun logLocationAuth(
        flow: String,
        source: String,
        location: Location,
        accepted: Boolean,
        rejectionReason: String? = null,
        persisted: Boolean = false,
        sentToBackend: Boolean = false,
    ) {
        if (!isDebugBuild()) {
            return
        }
        if (accepted) {
            logSuspiciousJump(flow, source, location)
            lastDebugAcceptedLocation = Location(location)
            lastDebugAcceptedSource = source
        }
        Log.d(
            logTag,
            "$locationAuthTag flow=$flow source=$source " +
                "lat=${"%.6f".format(Locale.US, location.latitude)} " +
                "lon=${"%.6f".format(Locale.US, location.longitude)} " +
                "alt=${if (location.hasAltitude()) "%.2f".format(Locale.US, location.altitude) else "none"} " +
                "accuracy=${if (location.hasAccuracy()) "%.2f".format(Locale.US, location.accuracy) else "none"} " +
                "timestamp=${location.time} ageMs=${locationAgeMs(location)} " +
                "authoritativeForBackend=true accepted=$accepted " +
                "rejectionReason=${rejectionReason ?: "none"} " +
                "persisted=$persisted sentToBackend=$sentToBackend",
        )
    }

    private fun logLocationAuthRaw(
        flow: String,
        source: String,
        accepted: Boolean,
        rejectionReason: String,
        persisted: Boolean,
        authoritativeForBackend: Boolean = false,
        latitude: Double? = null,
        longitude: Double? = null,
        timestamp: String? = null,
    ) {
        if (!isDebugBuild()) {
            return
        }
        Log.d(
            logTag,
            "$locationAuthTag flow=$flow source=$source " +
                "lat=${latitude?.let { "%.6f".format(Locale.US, it) } ?: "none"} " +
                "lon=${longitude?.let { "%.6f".format(Locale.US, it) } ?: "none"} " +
                "alt=none accuracy=none timestamp=${timestamp ?: "none"} " +
                "ageMs=${timestamp?.let { resolvedLocationAgeMs(it).toString() } ?: "none"} " +
                "authoritativeForBackend=$authoritativeForBackend accepted=$accepted " +
                "rejectionReason=$rejectionReason persisted=$persisted sentToBackend=false",
        )
    }

    private fun logSuspiciousJump(flow: String, source: String, location: Location) {
        if (!isDebugBuild()) {
            return
        }
        val previous = lastDebugAcceptedLocation ?: return
        val previousSource = lastDebugAcceptedSource ?: "unknown"
        val elapsedMs = kotlin.math.abs(location.time - previous.time)
        if (elapsedMs > suspiciousJumpWindowMs) {
            return
        }
        val distanceKm = distanceKm(
            previous.latitude,
            previous.longitude,
            location.latitude,
            location.longitude,
        )
        if (distanceKm <= suspiciousJumpKm) {
            return
        }
        Log.w(
            logTag,
            "$locationAuthTag[suspicious_jump] flow=$flow " +
                "previousLat=${"%.6f".format(Locale.US, previous.latitude)} " +
                "previousLon=${"%.6f".format(Locale.US, previous.longitude)} " +
                "newLat=${"%.6f".format(Locale.US, location.latitude)} " +
                "newLon=${"%.6f".format(Locale.US, location.longitude)} " +
                "distanceKm=${"%.2f".format(Locale.US, distanceKm)} " +
                "elapsedMs=$elapsedMs previousSource=$previousSource newSource=$source",
        )
    }

    private fun distanceKm(
        lat1: Double,
        lon1: Double,
        lat2: Double,
        lon2: Double,
    ): Double {
        val earthRadiusKm = 6371.0
        val dLat = Math.toRadians(lat2 - lat1)
        val dLon = Math.toRadians(lon2 - lon1)
        val a = sin(dLat / 2) * sin(dLat / 2) +
            cos(Math.toRadians(lat1)) *
            cos(Math.toRadians(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2)
        return earthRadiusKm * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    private fun isDebugBuild(): Boolean =
        (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    private fun resolvedLocationAgeMs(timestamp: String): Long {
        val parsed = resolvedLocationEpochMs(timestamp) ?: return Long.MAX_VALUE
        val ageMs = System.currentTimeMillis() - parsed
        return if (ageMs < -resolvedLocationMaxAgeMs) {
            Long.MAX_VALUE
        } else {
            ageMs.coerceAtLeast(0L)
        }
    }

    private fun resolvedLocationEpochMs(timestamp: String): Long? {
        return try {
            val trimmed = timestamp.trim()
            trimmed.toLongOrNull()?.let { numeric ->
                return if (trimmed.length <= 10) numeric * 1000L else numeric
            }
            val normalizedTimestamp = normalizeIsoTimestamp(trimmed)
            val formatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
            formatter.timeZone = TimeZone.getTimeZone("UTC")
            formatter.parse(normalizedTimestamp)?.time
        } catch (_: Exception) {
            null
        }
    }

    private fun normalizeIsoTimestamp(timestamp: String): String {
        val trimmed = timestamp.trim()
        val zIndex = trimmed.indexOf('Z')
        val dotIndex = trimmed.indexOf('.')
        if (zIndex <= 0 || dotIndex <= 0 || dotIndex > zIndex) {
            return trimmed
        }
        val fraction = trimmed.substring(dotIndex + 1, zIndex)
        val millis = fraction.padEnd(3, '0').take(3)
        return trimmed.substring(0, dotIndex + 1) + millis + trimmed.substring(zIndex)
    }

    private fun buildNotification(): Notification {
        return buildForegroundNotification(
            title = store.notificationTitle(),
            body = store.notificationBody(),
        )
    }

    private fun buildForegroundNotification(
        title: String? = null,
        body: String? = null,
    ): Notification {
        val resolvedTitle = title ?: defaultNotificationTitle
        val resolvedBody = body ?: defaultNotificationBody
        return NotificationCompat.Builder(this, notificationChannelId)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle(resolvedTitle)
            .setContentText(resolvedBody)
            .setContentIntent(NotificationLaunchIntents.contentIntentForLaunchingApp(this))
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Stop location sharing",
                PendingIntent.getService(
                    this,
                    notificationId,
                    Intent(this, EixamTelemetryForegroundService::class.java).apply {
                        action = actionStop
                    },
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
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
            true
        } catch (error: SecurityException) {
            store.markError("foreground_start_failed: ${error.message ?: error.javaClass.simpleName}")
            store.markStopped()
            stopSelf()
            false
        } catch (error: Exception) {
            store.markError("foreground_start_failed: ${error.message ?: error.javaClass.simpleName}")
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
    }

    private fun logTelemetryRestBlocked(reason: String) {
        val now = System.currentTimeMillis()
        if (now - lastRestBlockedLogAtMs < restBlockedLogIntervalMs) {
            return
        }
        lastRestBlockedLogAtMs = now
        Log.w(
            logTag,
            "TELEMETRY_REST_BLOCKED source=native_background " +
                "reason=telemetry_must_use_mqtt trigger=$reason",
        )
    }

    private fun shouldBlockRestTelemetry(): Boolean = true

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

    private fun looksLikeBleMac(value: String): Boolean =
        Regex("^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$").matches(value)

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
        private const val locationAuthTag = "[EIXAM_LOCATION_AUTH]"
        private const val logPrefix = "[SDK_BG_TELEMETRY]"
        private const val notificationChannelId = "eixam_background_telemetry"
        private const val notificationId = 6031
        private const val defaultNotificationTitle = "EIXAM"
        private const val defaultNotificationBody = "EIXAM"
        private const val actionStart = "dev.eixam.connect.flutter.action.TELEMETRY_START"
        private const val actionUpdate = "dev.eixam.connect.flutter.action.TELEMETRY_UPDATE"
        private const val actionStop = "dev.eixam.connect.flutter.action.TELEMETRY_STOP"
        private const val normalIntervalMs = 60000L
        private const val sosIntervalMs = 20000L
        private const val locationTimeoutMs = 8000L
        private const val normalCachedLocationMaxAgeMs = 45000L
        private const val sosCachedLocationMaxAgeMs = 15000L
        private const val sosMovementThresholdMeters = 7f
        private const val flutterPrefsName = "FlutterSharedPreferences"
        private const val flutterKeyPrefix = "flutter."
        private const val resolvedLocationKey = "eixam.location.resolved"
        private const val resolvedLocationHandoffVersionKey = "resolvedLocationHandoffVersion"
        private const val resolvedLocationHandoffVersion = 2
        private const val geoDecoderVersionKey = "geoDecoderVersion"
        private const val expectedGeoDecoderVersion = "firmware_tel_sos_v2"
        private const val resolvedLocationMaxAgeMs = 120000L
        private const val suspiciousJumpKm = 50.0
        private const val suspiciousJumpWindowMs = 600000L
        private const val restBlockedLogIntervalMs = 300000L

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
