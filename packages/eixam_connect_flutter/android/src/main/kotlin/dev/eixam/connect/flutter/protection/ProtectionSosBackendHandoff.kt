package dev.eixam.connect.flutter.protection

import android.content.Context
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
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
                val apiBaseUrl = runtimeStore.currentApiBaseUrl() ?: return@execute
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
                val apiBaseUrl = runtimeStore.currentApiBaseUrl()
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
            val apiBaseUrl = runtimeStore.currentApiBaseUrl()
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
        val response = sendRequest(
            method = "POST",
            url = normalizeUrl(apiBaseUrl, "/v1/sdk/sos"),
            session = session,
            body = payload.toString(),
        )
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
        val raw =
            flutterPreferences.getString("$flutterKeyPrefix${trackingPositionKey}", null)
                ?: return null
        val json = JSONObject(raw)
        if (!json.has("latitude") || !json.has("longitude") || !json.has("timestamp")) {
            return null
        }
        return TrackingPositionSnapshot(
            latitude = json.getDouble("latitude"),
            longitude = json.getDouble("longitude"),
            altitude = if (json.isNull("altitude")) null else json.optDouble("altitude"),
            timestamp = json.getString("timestamp"),
        )
    }

    private fun normalizeUrl(
        baseUrl: String,
        path: String,
    ): String {
        val normalizedBase = if (baseUrl.endsWith("/")) baseUrl.dropLast(1) else baseUrl
        val normalizedPath = if (path.startsWith("/")) path else "/$path"
        return normalizedBase + normalizedPath
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

    companion object {
        private const val flutterPrefsName = "FlutterSharedPreferences"
        private const val flutterKeyPrefix = "flutter."
        private const val sdkSessionKey = "eixam.sdk.session"
        private const val trackingPositionKey = "eixam.tracking.last_position"
    }
}
