package dev.eixam.connect.flutter.protection

import android.content.Context
import android.content.pm.ApplicationInfo
import android.util.Log
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

internal class ProtectionSosBackendHandoff(
    private val context: Context,
    private val runtimeStore: ProtectionRuntimeStore,
    private val scheduleRetry: (String) -> Unit,
) {
    private val executor = Executors.newSingleThreadExecutor()
    private val flutterPreferences =
        context.getSharedPreferences(flutterPrefsName, Context.MODE_PRIVATE)
    private val registeredBackendNodeIds = mutableSetOf<Int>()

    fun dispose() {
        executor.shutdownNow()
    }

    fun queueCreate(reason: String) {
        runtimeStore.markPendingSosCreate()
        runtimeStore.markBackendHandoffQueued("create_queued")
        ProtectionRuntimeBridge.recordPlatformEvent(
            context = context,
            type = "nativeBackendSyncQueued",
            reason = "create:$reason",
        )
        flushPendingActions(reason)
    }

    fun queueCancel(reason: String) {
        runtimeStore.markPendingSosCancel()
        runtimeStore.markBackendHandoffQueued("cancel_queued")
        ProtectionRuntimeBridge.recordPlatformEvent(
            context = context,
            type = "nativeBackendSyncQueued",
            reason = "cancel:$reason",
        )
        flushPendingActions(reason)
    }

    fun flushPendingActions(reason: String) {
        executor.execute {
            flushPendingActionsInternal(reason)
        }
    }

    fun flushPendingActionsSync(reason: String): Map<String, Any> {
        val latch = CountDownLatch(1)
        var flushedCreate = 0
        var flushedCancel = 0
        executor.execute {
            val result = flushPendingActionsInternal(reason)
            flushedCreate = result.flushedCreate
            flushedCancel = result.flushedCancel
            latch.countDown()
        }
        latch.await(15, TimeUnit.SECONDS)
        return mapOf(
            "flushedSosCount" to (flushedCreate + flushedCancel),
            "flushedTelemetryCount" to 0,
            "success" to true,
        )
    }

    fun rehydrateBackendState(reason: String) {
        executor.execute {
            try {
                val session = loadSession() ?: return@execute
                val apiBaseUrl = requireValidatedApiBaseUrl() ?: return@execute
                val existingIncident = fetchActiveIncident(apiBaseUrl, session)
                if (existingIncident != null) {
                    runtimeStore.markBackendIncidentActive(
                        incidentId = existingIncident.id,
                        incidentState = existingIncident.state,
                    )
                    ProtectionRuntimeBridge.recordPlatformEvent(
                        context = context,
                        type = "nativeBackendSyncSucceeded",
                        reason = "rehydrated:${existingIncident.state}",
                    )
                }
            } catch (error: Exception) {
                runtimeStore.markBackendHandoffFailure(error.message ?: "backend_rehydrate_failed")
                ProtectionRuntimeBridge.recordPlatformEvent(
                    context = context,
                    type = "nativeBackendSyncFailed",
                    reason = "rehydrate:${error.message ?: "unknown"}",
                )
                scheduleRetry("backend_rehydrate_failed")
            }
        }
    }

    private fun flushPendingActionsInternal(reason: String): FlushResult {
        var flushedCreate = 0
        var flushedCancel = 0

        if (runtimeStore.hasPendingNativeSosCreate() && syncCreate(reason)) {
            flushedCreate = 1
        }
        if (runtimeStore.hasPendingNativeSosCancel() && syncCancel(reason)) {
            flushedCancel = 1
        }

        return FlushResult(
            flushedCreate = flushedCreate,
            flushedCancel = flushedCancel,
        )
    }

    private fun syncCreate(reason: String): Boolean {
        return try {
            if (runtimeStore.activeBackendIncidentId()?.isNotBlank() == true) {
                runtimeStore.clearPendingSosCreate()
                runtimeStore.markBackendHandoffSuccess("create_already_synced")
                ProtectionRuntimeBridge.recordPlatformEvent(
                    context = context,
                    type = "nativeBackendSyncSucceeded",
                    reason = "create_already_synced",
                )
                true
            } else {
                val session = loadSession()
                    ?: throw IllegalStateException("Missing SDK session for native SOS backend handoff.")
                val apiBaseUrl = requireValidatedApiBaseUrl()
                    ?: throw IllegalStateException("Missing API base URL for native SOS backend handoff.")
                val position = loadTrackingPosition()
                    ?: throw IllegalStateException("Missing tracking position for native SOS backend handoff.")
                val existingIncident = fetchActiveIncident(apiBaseUrl, session)
                if (existingIncident != null) {
                    runtimeStore.markBackendIncidentActive(
                        incidentId = existingIncident.id,
                        incidentState = existingIncident.state,
                    )
                    runtimeStore.clearPendingSosCreate()
                    runtimeStore.markBackendHandoffSuccess("create_already_exists")
                    ProtectionRuntimeBridge.recordPlatformEvent(
                        context = context,
                        type = "nativeBackendSyncSucceeded",
                        reason = "create_already_exists",
                    )
                    true
                } else {
                    val createdIncident = createIncident(apiBaseUrl, session, position)
                    runtimeStore.markBackendIncidentActive(
                        incidentId = createdIncident.id,
                        incidentState = createdIncident.state,
                    )
                    runtimeStore.clearPendingSosCreate()
                    ProtectionRuntimeBridge.recordPlatformEvent(
                        context = context,
                        type = "nativeBackendSyncSucceeded",
                        reason = "create_synced:${createdIncident.id ?: "unknown"}",
                    )
                    true
                }
            }
        } catch (error: Exception) {
            handleFailure(
                action = "create",
                reason = reason,
                error = error,
            )
            false
        }
    }

    private fun syncCancel(reason: String): Boolean {
        return try {
            val session = loadSession()
                ?: throw IllegalStateException("Missing SDK session for native SOS backend cancel.")
            val apiBaseUrl = requireValidatedApiBaseUrl()
                ?: throw IllegalStateException("Missing API base URL for native SOS backend cancel.")
            val existingIncident = runtimeStore.activeBackendIncidentId()?.let {
                BackendIncident(id = it, state = runtimeStore.lastBackendIncidentState())
            } ?: fetchActiveIncident(apiBaseUrl, session)

            if (existingIncident == null) {
                runtimeStore.clearPendingSosCancel()
                runtimeStore.markBackendIncidentCleared("cancel_no_active_incident")
                ProtectionRuntimeBridge.recordPlatformEvent(
                    context = context,
                    type = "nativeBackendSyncSucceeded",
                    reason = "cancel_no_active_incident",
                )
                true
            } else {
                cancelIncident(apiBaseUrl, session)
                runtimeStore.clearPendingSosCancel()
                runtimeStore.markBackendIncidentCleared("cancel_synced")
                ProtectionRuntimeBridge.recordPlatformEvent(
                    context = context,
                    type = "nativeBackendSyncSucceeded",
                    reason = "cancel_synced:${existingIncident.id ?: "unknown"}",
                )
                true
            }
        } catch (error: Exception) {
            handleFailure(
                action = "cancel",
                reason = reason,
                error = error,
            )
            false
        }
    }

    private fun handleFailure(
        action: String,
        reason: String,
        error: Exception,
    ) {
        val message = error.message ?: "${action}_failed"
        runtimeStore.markBackendHandoffFailure(message)
        ProtectionRuntimeBridge.recordPlatformEvent(
            context = context,
            type = "nativeBackendSyncFailed",
            reason = "$action:$message",
        )
        scheduleRetry("${action}_handoff_retry:$reason")
    }

    private fun createIncident(
        apiBaseUrl: String,
        session: SessionSnapshot,
        position: TrackingPositionSnapshot,
    ): BackendIncident {
        val payload = JSONObject()
            .put("timestamp", position.timestamp)
            .put("latitude", position.latitude)
            .put("longitude", position.longitude)
            .put("altitude", position.altitude)
        val nodeId = runtimeStore.currentBoundNodeId()
        val hardwareId = currentBleHardwareIdForBackendPayload()
            ?.trim()
            ?.takeIf { it.isNotBlank() }
        if (nodeId != null) {
            payload
                .put("deviceId", nodeId.toString())
                .put("nodeId", nodeId)
                .put("originatorNodeId", nodeId)
                .put("identitySource", "ble_node")
        } else {
            payload.put(
                "identitySource",
                if (hardwareId == null) "app" else "device_hardware_pending",
            )
        }
        hardwareId?.let {
            payload.put("hardwareId", it)
            if (nodeId == null && !looksLikeBleMac(it)) {
                payload.put("deviceId", it)
            }
        }
        if (nodeId != null) {
            registerBackendDevice(
                apiBaseUrl = apiBaseUrl,
                session = session,
                nodeId = nodeId,
                bleHardwareId = hardwareId,
            )
        }
        val correlationId = nextCorrelationId("sos-native")
        Log.i(
            logTag,
            "[SOS_BACKEND_OUTBOUND_FINAL] transport=http endpoint=/v1/sdk/sos " +
                "correlationId=$correlationId source=native_protection_sos owner=device " +
                "deviceId=${payload.optStringOrNone("deviceId")} " +
                "nodeId=${nodeId?.toString() ?: "none"} " +
                "originatorNodeId=${payload.optStringOrNone("originatorNodeId")} " +
                "hardwareId=${payload.optStringOrNone("hardwareId")} " +
                "identitySource=${payload.optStringOrNone("identitySource")} " +
                "incidentId=none canonicalIncidentId=none " +
                "payload=${redactedCompactJson(payload)}",
        )
        val response = sendRequest(
            method = "POST",
            url = normalizeUrl(apiBaseUrl, "/v1/sdk/sos"),
            session = session,
            body = payload.toString(),
        )
        Log.i(
            logTag,
            "[SOS_BACKEND_RESPONSE] correlationId=$correlationId " +
                "status=${response.statusCode} " +
                "backendIncidentId=${backendIncidentIdFrom(response.body) ?: "none"} " +
                "responseSummary=${compactSummary(response.body)}",
        )
        if (response.statusCode == 422 || response.statusCode == 402) {
            Log.w(
                logTag,
                "SOS_RUNTIME_BACKEND_DELIVERY_FAILED status=${response.statusCode} " +
                    "failure=backend_validation_error pendingSos=1 " +
                    "localSosPreserved=true correlationId=$correlationId " +
                    "deviceId=${payload.optStringOrNone("deviceId")} " +
                    "nodeId=${payload.optStringOrNone("nodeId")} " +
                    "originatorNodeId=${payload.optStringOrNone("originatorNodeId")} " +
                    "hardwareId=${payload.optStringOrNone("hardwareId")}",
            )
            if (nodeId != null && isReferencedDeviceMissing(response.body)) {
                registerBackendDevice(
                    apiBaseUrl = apiBaseUrl,
                    session = session,
                    nodeId = nodeId,
                    bleHardwareId = hardwareId,
                    force = true,
                )
                val retryCorrelationId = nextCorrelationId("sos-native-retry")
                Log.i(
                    logTag,
                    "[SOS_BACKEND_RETRY_AFTER_DEVICE_REGISTER] " +
                        "originalCorrelationId=$correlationId " +
                        "retryCorrelationId=$retryCorrelationId " +
                        "nodeId=$nodeId backendHardwareId=${nodeId} " +
                        "reason=referenced_device_does_not_exist",
                )
                val retryResponse = sendRequest(
                    method = "POST",
                    url = normalizeUrl(apiBaseUrl, "/v1/sdk/sos"),
                    session = session,
                    body = payload.toString(),
                )
                Log.i(
                    logTag,
                    "[SOS_BACKEND_RESPONSE] correlationId=$retryCorrelationId " +
                        "status=${retryResponse.statusCode} " +
                        "backendIncidentId=${backendIncidentIdFrom(retryResponse.body) ?: "none"} " +
                        "responseSummary=${compactSummary(retryResponse.body)}",
                )
                if (retryResponse.statusCode in 200..299) {
                    return parseIncidentResponse(retryResponse.body)
                        ?: throw IllegalStateException("Native SOS create did not return an incident payload.")
                }
            }
        }
        if (response.statusCode !in 200..299) {
            throw IllegalStateException("Native SOS create failed: ${response.statusCode} ${response.body}")
        }
        return parseIncidentResponse(response.body)
            ?: throw IllegalStateException("Native SOS create did not return an incident payload.")
    }

    private fun cancelIncident(
        apiBaseUrl: String,
        session: SessionSnapshot,
    ) {
        val response = sendRequest(
            method = "POST",
            url = normalizeUrl(apiBaseUrl, "/v1/sdk/sos/cancel"),
            session = session,
            body = null,
        )
        if (response.statusCode !in 200..299) {
            throw IllegalStateException("Native SOS cancel failed: ${response.statusCode} ${response.body}")
        }
    }

    private fun fetchActiveIncident(
        apiBaseUrl: String,
        session: SessionSnapshot,
    ): BackendIncident? {
        val response = sendRequest(
            method = "GET",
            url = normalizeUrl(apiBaseUrl, "/v1/sdk/sos"),
            session = session,
            body = null,
        )
        if (response.statusCode !in 200..299) {
            throw IllegalStateException("Native SOS get-active failed: ${response.statusCode} ${response.body}")
        }
        return parseIncidentResponse(response.body)
    }

    private fun sendRequest(
        method: String,
        url: String,
        session: SessionSnapshot,
        body: String?,
    ): HttpResponse {
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 15000
            readTimeout = 15000
            doInput = true
            setRequestProperty("Accept", "application/json")
            setRequestProperty("Authorization", "Bearer ${session.userHash}")
            setRequestProperty("X-App-ID", session.appId)
            setRequestProperty("X-User-ID", session.externalUserId)
            if (body != null) {
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
            }
        }

        try {
            if (body != null) {
                OutputStreamWriter(connection.outputStream, Charsets.UTF_8).use { writer ->
                    writer.write(body)
                    writer.flush()
                }
            }

            val responseCode = connection.responseCode
            val stream = if (responseCode in 200..299) {
                connection.inputStream
            } else {
                connection.errorStream ?: connection.inputStream
            }
            val payload = stream?.bufferedReader()?.use { reader -> reader.readText() }.orEmpty()
            return HttpResponse(
                statusCode = responseCode,
                body = payload,
            )
        } finally {
            connection.disconnect()
        }
    }

    private fun registerBackendDevice(
        apiBaseUrl: String,
        session: SessionSnapshot,
        nodeId: Int,
        bleHardwareId: String?,
        force: Boolean = false,
    ) {
        if (!force && registeredBackendNodeIds.contains(nodeId)) {
            return
        }
        val backendHardwareId = nodeId.toString()
        val diagnosticBleHardwareId = bleHardwareId
            ?.trim()
            ?.takeIf { it.isNotBlank() }
            ?: currentBleHardwareIdForBackendPayload()
        val firmwareVersion = runtimeStore.currentFirmwareVersion()
            ?.trim()
            ?.takeIf { it.isNotBlank() }
        val hardwareModel = runtimeStore.currentHardwareModel()
            ?.trim()
            ?.takeIf { it.isNotBlank() }
        if (firmwareVersion == null || hardwareModel == null) {
            Log.w(
                logTag,
                "[DEVICE_BACKEND_REGISTER_SKIPPED] reason=missing_metadata " +
                    "backendHardwareId=$backendHardwareId nodeId=$nodeId " +
                    "bleHardwareId=${diagnosticBleHardwareId ?: "none"} " +
                    "firmwareVersion=${firmwareVersion ?: "none"} " +
                    "hardwareModel=${hardwareModel ?: "none"}",
            )
            return
        }
        val pairedAt = isoNow()
        val payload = JSONObject()
            .put("hardware_id", backendHardwareId)
            .put("firmware_version", firmwareVersion)
            .put("hardware_model", hardwareModel)
            .put("paired_at", pairedAt)
        val response = sendRequest(
            method = "POST",
            url = normalizeUrl(apiBaseUrl, "/v1/sdk/devices"),
            session = session,
            body = payload.toString(),
        )
        Log.i(
            logTag,
            "[DEVICE_BACKEND_REGISTER_RESPONSE] status=${response.statusCode} " +
                "backendDeviceId=${backendDeviceIdFrom(response.body) ?: "none"} " +
                "backendHardwareId=$backendHardwareId " +
                "responseSummary=${compactSummary(response.body)}",
        )
        if (response.statusCode !in 200..299) {
            throw IllegalStateException("Native device registration failed: ${response.statusCode} ${response.body}")
        }
        registeredBackendNodeIds.add(nodeId)
    }

    private fun currentBleHardwareIdForBackendPayload(): String? {
        runtimeStore.currentBleHardwareId()
            ?.trim()
            ?.takeIf { it.isNotBlank() }
            ?.let { return it }
        return runtimeStore.currentBackendHardwareId()
            ?.trim()
            ?.takeIf { it.isNotBlank() && looksLikeBleMac(it) }
    }

    private fun parseIncidentResponse(body: String): BackendIncident? {
        if (body.isBlank()) {
            return null
        }
        val payload = JSONObject(body)
        if (payload.isNull("incident")) {
            return null
        }
        val incident = payload.optJSONObject("incident") ?: return null
        return BackendIncident(
            id = incident.optString("id").takeIf { it.isNotBlank() },
            state = incident.optString("state").takeIf { it.isNotBlank() },
        )
    }

    private fun loadSession(): SessionSnapshot? {
        val raw = flutterPreferences.getString("$flutterKeyPrefix${sdkSessionKey}", null)
            ?: return null
        val json = JSONObject(raw)
        val appId = json.optString("appId").trim()
        val externalUserId = json.optString("externalUserId").trim()
        val userHash = json.optString("userHash").trim()
        if (appId.isEmpty() || externalUserId.isEmpty() || userHash.isEmpty()) {
            return null
        }
        return SessionSnapshot(
            appId = appId,
            externalUserId = externalUserId,
            userHash = userHash,
        )
    }

    private fun loadTrackingPosition(): TrackingPositionSnapshot? {
        loadResolvedAuthoritativePosition()?.let {
            return it
        }
        val raw =
            flutterPreferences.getString("$flutterKeyPrefix${trackingPositionKey}", null)
                ?: return null
        val json = JSONObject(raw)
        if (!json.has("latitude") || !json.has("longitude") || !json.has("timestamp")) {
            return null
        }
        val timestamp = json.getString("timestamp")
        if (resolvedLocationAgeMs(timestamp) > resolvedLocationMaxAgeMs) {
            return null
        }
        val latitude = json.getDouble("latitude")
        val longitude = json.getDouble("longitude")
        if (!isValidCoordinate(latitude, longitude)) {
            return null
        }
        return TrackingPositionSnapshot(
            latitude = latitude,
            longitude = longitude,
            altitude = if (json.isNull("altitude")) null else json.optDouble("altitude"),
            timestamp = timestamp,
        )
    }

    private fun loadResolvedAuthoritativePosition(): TrackingPositionSnapshot? {
        val raw =
            flutterPreferences.getString("$flutterKeyPrefix${resolvedLocationKey}", null)
                ?: return null
        val json = JSONObject(raw)
        if (!json.optBoolean("authoritativeForBackend", false)) {
            return null
        }
        val source = json.optString("source")
        if (source == "cachedFallback" || source == "backendSnapshot" || source.isBlank()) {
            return null
        }
        if (!json.has("latitude") || !json.has("longitude") || !json.has("timestamp")) {
            return null
        }
        val timestamp = json.getString("timestamp")
        if (resolvedLocationAgeMs(timestamp) > resolvedLocationMaxAgeMs) {
            return null
        }
        val latitude = json.getDouble("latitude")
        val longitude = json.getDouble("longitude")
        if (!isValidCoordinate(latitude, longitude)) {
            return null
        }
        return TrackingPositionSnapshot(
            latitude = latitude,
            longitude = longitude,
            altitude = if (json.isNull("altitudeMeters")) null else json.optDouble("altitudeMeters"),
            timestamp = timestamp,
        )
    }

    private fun isValidCoordinate(latitude: Double, longitude: Double): Boolean =
        latitude.isFinite() &&
            longitude.isFinite() &&
            latitude in -90.0..90.0 &&
            longitude in -180.0..180.0 &&
            !(latitude == 0.0 && longitude == 0.0)

    private fun resolvedLocationAgeMs(timestamp: String): Long {
        return try {
            val normalizedTimestamp = normalizeIsoTimestamp(timestamp)
            val formatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
            formatter.timeZone = TimeZone.getTimeZone("UTC")
            val parsed = formatter.parse(normalizedTimestamp) ?: return Long.MAX_VALUE
            (System.currentTimeMillis() - parsed.time).coerceAtLeast(0L)
        } catch (_: Exception) {
            Long.MAX_VALUE
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

    private fun normalizeUrl(
        baseUrl: String,
        path: String,
    ): String {
        val normalizedBase = if (baseUrl.endsWith("/")) baseUrl.dropLast(1) else baseUrl
        val normalizedPath = if (path.startsWith("/")) path else "/$path"
        return normalizedBase + normalizedPath
    }

    private fun requireValidatedApiBaseUrl(): String? {
        val apiBaseUrl = runtimeStore.currentApiBaseUrl()?.trim()
        val validation = validateApiBaseUrl(apiBaseUrl)
        runtimeStore.recordNativeBackendConfig(
            apiBaseUrl = apiBaseUrl,
            isValid = validation.isValid,
            issue = validation.issue,
            debugLocalhostAllowed = validation.debugLocalhostAllowed,
            debugCleartextAllowed = validation.debugCleartextAllowed,
        )
        if (!validation.isValid) {
            throw IllegalStateException(validation.issue)
        }
        return apiBaseUrl
    }

    private fun validateApiBaseUrl(apiBaseUrl: String?): BackendConfigValidation {
        if (apiBaseUrl.isNullOrBlank()) {
            return BackendConfigValidation(
                isValid = false,
                issue = "Native Protection backend base URL is missing.",
            )
        }
        val uri = try {
            URI(apiBaseUrl)
        } catch (_: Exception) {
            return BackendConfigValidation(
                isValid = false,
                issue = "Native Protection backend base URL is invalid: $apiBaseUrl",
            )
        }
        val scheme = uri.scheme?.lowercase()
        val host = uri.host?.lowercase()
        if (scheme.isNullOrBlank() || host.isNullOrBlank()) {
            return BackendConfigValidation(
                isValid = false,
                issue = "Native Protection backend base URL must include scheme and host: $apiBaseUrl",
            )
        }
        val isLocalhost = host == "127.0.0.1" || host == "localhost"
        val isCleartext = scheme == "http"
        if (isDebugBuild()) {
            val debugIssues = mutableListOf<String>()
            if (isLocalhost) {
                debugIssues += "Debug localhost backend allowed"
            }
            if (isCleartext) {
                debugIssues += "Debug cleartext backend allowed"
            }
            return BackendConfigValidation(
                isValid = true,
                issue = debugIssues.takeIf { it.isNotEmpty() }?.joinToString(". "),
                debugLocalhostAllowed = isLocalhost,
                debugCleartextAllowed = isCleartext,
            )
        }
        if (isLocalhost) {
            return BackendConfigValidation(
                isValid = false,
                issue = "Localhost backend is not allowed in release builds: $apiBaseUrl",
            )
        }
        if (isCleartext) {
            return BackendConfigValidation(
                isValid = false,
                issue = "Cleartext backend is not allowed in release builds: $apiBaseUrl",
            )
        }
        return BackendConfigValidation(
            isValid = true,
            issue = null,
        )
    }

    private data class SessionSnapshot(
        val appId: String,
        val externalUserId: String,
        val userHash: String,
    )

    private data class TrackingPositionSnapshot(
        val latitude: Double,
        val longitude: Double,
        val altitude: Double?,
        val timestamp: String,
    )

    private data class BackendIncident(
        val id: String?,
        val state: String?,
    )

    private data class HttpResponse(
        val statusCode: Int,
        val body: String,
    )

    private data class FlushResult(
        val flushedCreate: Int,
        val flushedCancel: Int,
    )

    private data class BackendConfigValidation(
        val isValid: Boolean,
        val issue: String?,
        val debugLocalhostAllowed: Boolean = false,
        val debugCleartextAllowed: Boolean = false,
    )

    private fun isDebugBuild(): Boolean =
        (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    private fun nextCorrelationId(prefix: String): String =
        "$prefix-${System.currentTimeMillis()}"

    private fun redactedCompactJson(payload: JSONObject): String {
        val copy = JSONObject(payload.toString())
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

    private fun backendIncidentIdFrom(body: String): String? =
        try {
            JSONObject(body).optJSONObject("incident")
                ?.optString("id")
                ?.takeIf { it.isNotBlank() }
        } catch (_: Exception) {
            null
        }

    private fun backendDeviceIdFrom(body: String): String? =
        try {
            JSONObject(body).optJSONObject("device")
                ?.optString("id")
                ?.takeIf { it.isNotBlank() }
        } catch (_: Exception) {
            null
        }

    private fun isReferencedDeviceMissing(body: String): Boolean =
        body.contains("Referenced device does not exist", ignoreCase = true)

    private fun isoNow(): String {
        val formatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        formatter.timeZone = TimeZone.getTimeZone("UTC")
        return formatter.format(Date())
    }

    private fun JSONObject.optStringOrNone(key: String): String =
        if (has(key) && !isNull(key)) optString(key).takeIf { it.isNotBlank() } ?: "none" else "none"

    private fun looksLikeBleMac(value: String): Boolean =
        Regex("^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$").matches(value)

    companion object {
        private const val logTag = "ProtectionSosBackend"
        private const val flutterPrefsName = "FlutterSharedPreferences"
        private const val flutterKeyPrefix = "flutter."
        private const val sdkSessionKey = "eixam.sdk.session"
        private const val trackingPositionKey = "eixam.tracking.last_position"
        private const val resolvedLocationKey = "eixam.location.resolved"
        private const val resolvedLocationMaxAgeMs = 120_000L
    }
}
