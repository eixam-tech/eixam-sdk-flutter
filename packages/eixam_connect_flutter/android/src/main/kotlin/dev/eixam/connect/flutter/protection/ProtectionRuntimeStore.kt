package dev.eixam.connect.flutter.protection

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

internal class ProtectionRuntimeStore(context: Context) {
    private val preferences =
        context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)

    fun snapshot(): Map<String, Any?> {
        val serviceRunning = preferences.getBoolean(keyServiceRunning, false)
        val runtimeActive = preferences.getBoolean(keyRuntimeActive, false)
        val bleOwner = preferences.getString(keyBleOwner, "flutter") ?: "flutter"
        val serviceBleConnected =
            preferences.getBoolean(keyServiceBleConnected, false)
        val serviceBleReady = preferences.getBoolean(keyServiceBleReady, false)
        val backgroundCapabilityState =
            preferences.getString(keyBackgroundCapabilityState, "configured")
                ?: "configured"
        val reconnectAttemptCount =
            preferences.getInt(keyReconnectAttemptCount, 0)
        val lastReconnectAttemptAt =
            preferences.getLong(keyLastReconnectAttemptAt, 0L).takeIf { it > 0L }
        val pendingNativeSosCreateCount =
            preferences.getInt(keyPendingNativeSosCreateCount, 0)
        val pendingNativeSosCancelCount =
            preferences.getInt(keyPendingNativeSosCancelCount, 0)
        val pendingExternalRelayCancelCount = pendingExternalRelayCancelCount()
        val preSosExpectedActivationAt =
            preferences.getLong(keyPreSosExpectedActivationAt, 0L).takeIf { it > 0L }
        val preSosRemainingSeconds = preSosExpectedActivationAt?.let { deadline ->
            (((deadline - System.currentTimeMillis()).coerceAtLeast(0L) + 999L) / 1000L).toInt()
        }

        return mapOf(
            "platformRuntimeConfigured" to true,
            "foregroundServiceConfigured" to true,
            "backgroundCapabilityReady" to true,
            "backgroundCapabilityState" to backgroundCapabilityState,
            "restorationConfigured" to true,
            "serviceRunning" to serviceRunning,
            "runtimeActive" to runtimeActive,
            "bleOwner" to bleOwner,
            "serviceBleConnected" to serviceBleConnected,
            "serviceBleReady" to serviceBleReady,
            "protectedDeviceId" to preferences.getString(keyTargetDeviceId, null),
            "activeDeviceId" to preferences.getString(keyTargetDeviceId, null),
            "targetDeviceId" to preferences.getString(keyTargetDeviceId, null),
            "boundDeviceId" to preferences.getString(keyBoundDeviceId, null),
            "boundNodeId" to preferences.getIntOrNull(keyBoundNodeId),
            "expectedBleServiceUuid" to preferences.getString(keyExpectedBleServiceUuid, null),
            "expectedBleCharacteristicUuids" to
                (preferences.getString(keyExpectedBleCharacteristicUuids, null)
                    ?.split("|")
                    ?.filter { it.isNotBlank() }
                    ?: emptyList<String>()),
            "discoveredBleServicesSummary" to preferences.getString(keyDiscoveredBleServicesSummary, null),
            "readinessFailureReason" to preferences.getString(keyReadinessFailureReason, null),
            "targetDeviceId" to preferences.getString(keyTargetDeviceId, null),
            "nativeBackendBaseUrl" to preferences.getString(keyApiBaseUrl, null),
            "nativeBackendConfigValid" to preferences.getBoolean(keyNativeBackendConfigValid, true),
            "nativeBackendConfigIssue" to preferences.getString(keyNativeBackendConfigIssue, null),
            "debugLocalhostBackendAllowed" to
                preferences.getBoolean(keyDebugLocalhostBackendAllowed, false),
            "debugCleartextBackendAllowed" to
                preferences.getBoolean(keyDebugCleartextBackendAllowed, false),
            "lastFailureReason" to preferences.getString(keyLastFailureReason, null),
            "lastPlatformEvent" to preferences.getString(keyLastPlatformEvent, null),
            "lastPlatformEventAt" to preferences.getLong(keyLastPlatformEventAt, 0L)
                .takeIf { it > 0L },
            "lastWakeAt" to preferences.getLong(keyLastWakeAt, 0L).takeIf { it > 0L },
            "lastWakeReason" to preferences.getString(keyLastWakeReason, null),
            "lastRestorationEvent" to preferences.getString(keyLastRestorationEvent, null),
            "lastRestorationEventAt" to preferences.getLong(keyLastRestorationEventAt, 0L)
                .takeIf { it > 0L },
            "lastBleServiceEvent" to preferences.getString(keyLastBleServiceEvent, null),
            "lastBleServiceEventAt" to preferences.getLong(keyLastBleServiceEventAt, 0L)
                .takeIf { it > 0L },
            "reconnectAttemptCount" to reconnectAttemptCount,
            "lastReconnectAttemptAt" to lastReconnectAttemptAt,
            "pendingSosCount" to
                (preferences.getInt(keyPendingSosCount, 0) +
                    pendingNativeSosCreateCount +
                    pendingNativeSosCancelCount +
                    pendingExternalRelayCancelCount),
            "pendingTelemetryCount" to preferences.getInt(keyPendingTelemetryCount, 0),
            "pendingNativeSosCreateCount" to pendingNativeSosCreateCount,
            "pendingNativeSosCancelCount" to pendingNativeSosCancelCount,
            "pendingExternalRelayCancelCount" to pendingExternalRelayCancelCount,
            "runtimeState" to when {
                preferences.getString(keyLastPlatformEvent, null) == "runtimeStarting" -> "starting"
                preferences.getString(keyLastPlatformEvent, null) == "runtimeError" -> "failed"
                preferences.getString(keyLastPlatformEvent, null) == "runtimeFailed" -> "failed"
                runtimeActive -> "active"
                serviceRunning -> "recovering"
                else -> "inactive"
            },
            "coverageLevel" to when {
                serviceBleReady -> "full"
                runtimeActive || serviceRunning -> "partial"
                else -> "none"
            },
            "degradationReason" to currentDegradationReason(),
            "lastNativeBackendHandoffResult" to preferences.getString(
                keyLastNativeBackendHandoffResult,
                null,
            ),
            "lastNativeBackendHandoffError" to preferences.getString(
                keyLastNativeBackendHandoffError,
                null,
            ),
            "lastCommandRoute" to preferences.getString(keyLastCommandRoute, null),
            "lastCommandResult" to preferences.getString(keyLastCommandResult, null),
            "lastCommandError" to preferences.getString(keyLastCommandError, null),
            "preSosLifecycleState" to preferences.getString(keyPreSosLifecycleState, "idle"),
            "preSosCycleKey" to preferences.getString(keyPreSosCycleKey, null),
            "preSosOwner" to preferences.getString(keyPreSosOwner, null),
            "preSosStartedAt" to preferences.getLong(keyPreSosStartedAt, 0L).takeIf { it > 0L },
            "preSosExpectedActivationAt" to preSosExpectedActivationAt,
            "preSosRemainingSeconds" to preSosRemainingSeconds,
            "preSosOriginatorNodeId" to preferences.getIntOrNull(keyPreSosOriginatorNodeId),
            "preSosPacketId" to preferences.getIntOrNull(keyPreSosPacketId),
        )
    }

    fun markStartRequest(
        activeDeviceId: String?,
        backendHardwareId: String?,
        bleHardwareId: String?,
        firmwareVersion: String?,
        hardwareModel: String?,
        apiBaseUrl: String?,
        enableStoreAndForward: Boolean,
        hostAppManagedNotifications: Boolean,
        notificationTexts: Map<*, *>?,
    ) {
        preferences.edit()
            .putString(keyTargetDeviceId, activeDeviceId)
            .putString(keyBackendHardwareId, backendHardwareId)
            .putString(keyBleHardwareId, bleHardwareId?.trim()?.takeIf { it.isNotBlank() })
            .putString(keyFirmwareVersion, firmwareVersion?.trim()?.takeIf { it.isNotBlank() })
            .putString(keyHardwareModel, hardwareModel?.trim()?.takeIf { it.isNotBlank() })
            .putString(keyBoundDeviceId, activeDeviceId)
            .remove(keyBoundNodeId)
            .putString(keyApiBaseUrl, apiBaseUrl)
            .putBoolean(keyServiceRunning, true)
            .putBoolean(keyRuntimeActive, true)
            .putString(keyBleOwner, "androidService")
            .putBoolean(keyServiceBleConnected, false)
            .putBoolean(keyServiceBleReady, false)
            .putBoolean(keyHostAppManagedNotifications, hostAppManagedNotifications)
            .putNotificationText(
                keyProtectionModeTitle,
                notificationTexts,
                "protectionModeTitle",
            )
            .putNotificationText(
                keyProtectionModeBody,
                notificationTexts,
                "protectionModeBody",
            )
            .putNotificationText(
                keyProtectionModeChannelName,
                notificationTexts,
                "protectionModeChannelName",
            )
            .putNotificationText(
                keyProtectionModeChannelDescription,
                notificationTexts,
                "protectionModeChannelDescription",
            )
            .putNotificationText(
                keyProtectionSosChannelName,
                notificationTexts,
                "protectionSosChannelName",
            )
            .putNotificationText(
                keyProtectionSosChannelDescription,
                notificationTexts,
                "protectionSosChannelDescription",
            )
            .putNotificationText(
                keyProtectionPreSosTitle,
                notificationTexts,
                "protectionPreSosTitle",
            )
            .putNotificationText(
                keyProtectionPreSosBody,
                notificationTexts,
                "protectionPreSosBody",
            )
            .putNotificationText(
                keyProtectionSosActiveTitle,
                notificationTexts,
                "protectionSosActiveTitle",
            )
            .putNotificationText(
                keyProtectionSosActiveBody,
                notificationTexts,
                "protectionSosActiveBody",
            )
            .putNotificationText(
                keyProtectionSosResolvedTitle,
                notificationTexts,
                "protectionSosResolvedTitle",
            )
            .putNotificationText(
                keyProtectionSosResolvedBody,
                notificationTexts,
                "protectionSosResolvedBody",
            )
            .putString(keyReadinessFailureReason, null)
            .putString(keyDiscoveredBleServicesSummary, null)
            .putBoolean(keyStoreAndForwardEnabled, enableStoreAndForward)
            .putString(
                keyDegradationReason,
                "Android foreground service owns the Protection Mode runtime, but the service-owned BLE link is not connected yet.",
            )
            .remove(keyLastCommandRoute)
            .remove(keyLastCommandResult)
            .remove(keyLastCommandError)
            .putString(keyExpectedBleServiceUuid, expectedBleServiceUuid)
            .putString(keyExpectedBleCharacteristicUuids, expectedBleCharacteristicUuids.joinToString("|"))
            .remove(keyLastFailureReason)
            .putInt(keyReconnectAttemptCount, 0)
            .remove(keyLastReconnectAttemptAt)
            .putLong(keyLastWakeAt, System.currentTimeMillis())
            .putString(keyLastWakeReason, "enter_protection_mode")
            .apply()
    }

    fun markStopped() {
        preferences.edit()
            .putBoolean(keyServiceRunning, false)
            .putBoolean(keyRuntimeActive, false)
            .putString(keyBleOwner, "flutter")
            .putBoolean(keyServiceBleConnected, false)
            .putBoolean(keyServiceBleReady, false)
            .putString(keyDegradationReason, null)
            .putString(keyReadinessFailureReason, null)
            .apply()
    }

    fun markRuntimeFailure(reason: String) {
        preferences.edit()
            .putString(keyLastFailureReason, reason)
            .putBoolean(keyRuntimeActive, false)
            .putString(keyDegradationReason, reason)
            .putString(keyReadinessFailureReason, reason)
            .apply()
    }

    fun currentTargetDeviceId(): String? =
        preferences.getString(keyTargetDeviceId, null)

    fun currentBackendHardwareId(): String? =
        preferences.getString(keyBackendHardwareId, null)

    fun currentBleHardwareId(): String? =
        preferences.getString(keyBleHardwareId, null)

    fun currentFirmwareVersion(): String? =
        preferences.getString(keyFirmwareVersion, null)

    fun currentHardwareModel(): String? =
        preferences.getString(keyHardwareModel, null)

    fun saveBoundDeviceIdentity(
        boundDeviceId: String?,
        boundNodeId: Int?,
    ) {
        val editor = preferences.edit()
            .putString(keyBoundDeviceId, boundDeviceId)
        if (boundNodeId == null) {
            editor.remove(keyBoundNodeId)
        } else {
            editor.putInt(keyBoundNodeId, boundNodeId)
        }
        editor.apply()
    }

    fun currentBoundNodeId(): Int? =
        preferences.getIntOrNull(keyBoundNodeId)

    fun reconnectBackoffMs(defaultValue: Long): Long =
        preferences.getLong(keyReconnectBackoffMs, defaultValue).takeIf { it > 0L } ?: defaultValue

    fun saveReconnectBackoffMs(value: Long) {
        preferences.edit().putLong(keyReconnectBackoffMs, value).apply()
    }

    fun isProtectionArmed(): Boolean =
        preferences.getBoolean(keyServiceRunning, false) &&
            preferences.getString(keyBleOwner, "flutter") == "androidService"

    fun hostAppManagedNotifications(): Boolean =
        preferences.getBoolean(keyHostAppManagedNotifications, false)

    fun protectionModeTitle(): String =
        notificationText(keyProtectionModeTitle, "EIXAM")

    fun protectionModeBody(): String =
        notificationText(keyProtectionModeBody, "SOS")

    fun protectionModeChannelName(): String =
        notificationText(keyProtectionModeChannelName, "EIXAM")

    fun protectionModeChannelDescription(): String =
        notificationText(keyProtectionModeChannelDescription, "EIXAM")

    fun protectionSosChannelName(): String =
        notificationText(keyProtectionSosChannelName, "SOS")

    fun protectionSosChannelDescription(): String =
        notificationText(keyProtectionSosChannelDescription, "SOS")

    fun protectionPreSosTitle(): String =
        notificationText(keyProtectionPreSosTitle, "SOS pre-alert")

    fun protectionPreSosBody(): String =
        notificationText(keyProtectionPreSosBody, "SOS")

    fun protectionSosActiveTitle(): String =
        notificationText(keyProtectionSosActiveTitle, "SOS active")

    fun protectionSosActiveBody(): String =
        notificationText(keyProtectionSosActiveBody, "SOS")

    fun protectionSosResolvedTitle(): String =
        notificationText(keyProtectionSosResolvedTitle, "SOS resolved")

    fun protectionSosResolvedBody(): String =
        notificationText(keyProtectionSosResolvedBody, "SOS")

    private fun notificationText(key: String, fallback: String): String =
        preferences.getString(key, null)?.trim()?.takeIf { it.isNotBlank() } ?: fallback

    fun markServiceBleConnected() {
        preferences.edit()
            .putBoolean(keyServiceBleConnected, true)
            .putBoolean(keyRuntimeActive, true)
            .apply()
    }

    fun markServiceBleDisconnected() {
        preferences.edit()
            .putBoolean(keyServiceBleConnected, false)
            .putBoolean(keyServiceBleReady, false)
            .putString(
                keyDegradationReason,
                "Android foreground service is reconnecting to the protected BLE device.",
            )
            .putString(
                keyReadinessFailureReason,
                "Android foreground service is reconnecting to the protected BLE device.",
            )
            .apply()
    }

    fun markServiceBleReady() {
        preferences.edit()
            .putBoolean(keyServiceBleReady, true)
            .putString(keyReadinessFailureReason, null)
            .apply()
    }

    fun recordDiscoveredServicesSummary(summary: String) {
        preferences.edit()
            .putString(keyDiscoveredBleServicesSummary, summary)
            .apply()
    }

    fun recordReadinessFailureReason(reason: String?) {
        preferences.edit()
            .putString(keyReadinessFailureReason, reason)
            .apply()
    }

    fun recordCommandRoute(route: String) {
        preferences.edit()
            .putString(keyLastCommandRoute, route)
            .apply()
    }

    fun recordCommandResult(result: String?) {
        preferences.edit()
            .putString(keyLastCommandResult, result)
            .remove(keyLastCommandError)
            .apply()
    }

    fun recordCommandError(error: String?) {
        preferences.edit()
            .putString(keyLastCommandError, error)
            .apply()
    }

    fun recordNativeBackendConfig(
        apiBaseUrl: String?,
        isValid: Boolean,
        issue: String?,
        debugLocalhostAllowed: Boolean,
        debugCleartextAllowed: Boolean,
    ) {
        preferences.edit()
            .putString(keyApiBaseUrl, apiBaseUrl)
            .putBoolean(keyNativeBackendConfigValid, isValid)
            .putString(keyNativeBackendConfigIssue, issue)
            .putBoolean(keyDebugLocalhostBackendAllowed, debugLocalhostAllowed)
            .putBoolean(keyDebugCleartextBackendAllowed, debugCleartextAllowed)
            .apply()
    }

    fun markReconnectAttempt(count: Int) {
        preferences.edit()
            .putInt(keyReconnectAttemptCount, count)
            .putLong(keyLastReconnectAttemptAt, System.currentTimeMillis())
            .apply()
    }

    fun recordPacket(payload: List<Int>) {
        preferences.edit()
            .putString(
                keyLastPacketHex,
                payload.joinToString(separator = "") { byte -> "%02x".format(byte) },
            )
            .putLong(keyLastPacketAt, System.currentTimeMillis())
            .apply()
    }

    fun markPendingSosCreate() {
        preferences.edit()
            .putInt(keyPendingNativeSosCreateCount, 1)
            .putString(keyPendingSosState, "create_pending")
            .putString(keyPreSosLifecycleState, "createPending")
            .apply()
    }

    fun markPendingSosCancel() {
        preferences.edit()
            .putInt(keyPendingNativeSosCancelCount, 1)
            .putString(keyPendingSosState, "cancel_pending")
            .putString(keyPreSosLifecycleState, "cancelPending")
            .apply()
    }

    fun clearPendingSosCreate() {
        preferences.edit()
            .putInt(keyPendingNativeSosCreateCount, 0)
            .apply()
    }

    fun clearPendingSosCancel() {
        preferences.edit()
            .putInt(keyPendingNativeSosCancelCount, 0)
            .apply()
    }

    fun clearPendingSos() {
        preferences.edit()
            .putInt(keyPendingSosCount, 0)
            .putInt(keyPendingNativeSosCreateCount, 0)
            .putInt(keyPendingNativeSosCancelCount, 0)
            .putString(keyPendingSosState, "idle")
            .putString(keyPreSosLifecycleState, "idle")
            .remove(keyPreSosCycleKey)
            .remove(keyPreSosOwner)
            .remove(keyPreSosStartedAt)
            .remove(keyPreSosExpectedActivationAt)
            .remove(keyPreSosOriginatorNodeId)
            .remove(keyPreSosPacketId)
            .remove(keyActiveBackendIncidentId)
            .remove(keyActiveBackendIncidentState)
            .remove(keyActiveBackendIncidentAt)
            .apply()
    }

    fun recordPendingExternalRelayCancel(
        originatorNodeId: Int,
        relayNodeId: Int?,
        relayHardwareId: String?,
        rawPayloadHex: String?,
        source: String = "remote_lora_relay",
        timestamp: Long = System.currentTimeMillis(),
    ): Boolean {
        val normalizedOriginatorNodeId = normalizeNodeId(originatorNodeId)
        val normalizedRelayNodeId = relayNodeId?.let(::normalizeNodeId)
        val dedupeKey = listOf(
            normalizedOriginatorNodeId.toString(),
            normalizedRelayNodeId?.toString() ?: "none",
            rawPayloadHex?.trim()?.takeIf { it.isNotBlank() } ?: "none",
        ).joinToString(":")
        val existing = pendingExternalRelayCancels()
        if (existing.any { it["dedupeKey"] == dedupeKey }) {
            return false
        }
        val updated = existing + mapOf(
            "originatorNodeId" to normalizedOriginatorNodeId,
            "relayNodeId" to normalizedRelayNodeId,
            "relayHardwareId" to relayHardwareId?.trim()?.takeIf { it.isNotBlank() },
            "payloadHex" to rawPayloadHex?.trim()?.takeIf { it.isNotBlank() },
            "source" to source,
            "timestamp" to timestamp,
            "dedupeKey" to dedupeKey,
            "signature" to dedupeKey,
        )
        preferences.edit()
            .putString(keyPendingExternalRelayCancels, encodePendingExternalRelayCancels(updated))
            .apply()
        return true
    }

    fun peekPendingExternalRelayCancels(): List<Map<String, Any?>> =
        pendingExternalRelayCancels()

    fun ackPendingExternalRelayCancel(signature: String): Boolean {
        val normalizedSignature = signature.trim()
        if (normalizedSignature.isBlank()) {
            return false
        }
        val pending = pendingExternalRelayCancels()
        val remaining = pending.filterNot { event ->
            event["signature"] == normalizedSignature ||
                event["dedupeKey"] == normalizedSignature
        }
        if (remaining.size == pending.size) {
            return false
        }
        val editor = preferences.edit()
        if (remaining.isEmpty()) {
            editor.remove(keyPendingExternalRelayCancels)
        } else {
            editor.putString(
                keyPendingExternalRelayCancels,
                encodePendingExternalRelayCancels(remaining),
            )
        }
        editor.apply()
        return true
    }

    private fun pendingExternalRelayCancelCount(): Int =
        pendingExternalRelayCancels().size

    private fun pendingExternalRelayCancels(): List<Map<String, Any?>> {
        val raw = preferences.getString(keyPendingExternalRelayCancels, null)
            ?: return emptyList()
        return try {
            val array = JSONArray(raw)
            buildList {
                for (index in 0 until array.length()) {
                    val item = array.optJSONObject(index) ?: continue
                    val rawOriginatorNodeId = item.optLong("originatorNodeId", Long.MIN_VALUE)
                    if (rawOriginatorNodeId == Long.MIN_VALUE) {
                        continue
                    }
                    val originatorNodeId = normalizeNodeId(rawOriginatorNodeId)
                    val relayNodeId = if (item.has("relayNodeId") && !item.isNull("relayNodeId")) {
                        normalizeNodeId(item.optLong("relayNodeId"))
                    } else {
                        null
                    }
                    val payloadHex = item.optNullableString("payloadHex")
                    val normalizedDedupeKey = listOf(
                        originatorNodeId.toString(),
                        relayNodeId?.toString() ?: "none",
                        payloadHex?.trim()?.takeIf { it.isNotBlank() } ?: "none",
                    ).joinToString(":")
                    add(
                        mapOf(
                            "originatorNodeId" to originatorNodeId,
                            "relayNodeId" to relayNodeId,
                            "relayHardwareId" to item.optNullableString("relayHardwareId"),
                            "payloadHex" to payloadHex,
                            "source" to (item.optNullableString("source") ?: "remote_lora_relay"),
                            "timestamp" to item.optLong("timestamp", System.currentTimeMillis()),
                            "dedupeKey" to normalizedDedupeKey,
                            "signature" to (
                                item.optNullableString("signature")
                                    ?: item.optNullableString("dedupeKey")
                                    ?: normalizedDedupeKey
                                ),
                        ),
                    )
                }
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun encodePendingExternalRelayCancels(
        pending: List<Map<String, Any?>>,
    ): String {
        val array = JSONArray()
        for (event in pending) {
            val item = JSONObject()
            for ((key, value) in event) {
                item.put(key, value ?: JSONObject.NULL)
            }
            array.put(item)
        }
        return array.toString()
    }

    private fun normalizeNodeId(nodeId: Int): Long = normalizeNodeId(nodeId.toLong())

    private fun normalizeNodeId(nodeId: Long): Long = nodeId and 0xFFFF_FFFFL

    fun recordPreSosLifecycle(
        state: String,
        cycleKey: String?,
        owner: String?,
        startedAt: Long?,
        expectedActivationAt: Long?,
        originatorNodeId: Int?,
        packetId: Int?,
    ) {
        val editor = preferences.edit()
            .putString(keyPreSosLifecycleState, state)
            .putString(keyPendingSosState, state)
        if (cycleKey == null) editor.remove(keyPreSosCycleKey) else editor.putString(keyPreSosCycleKey, cycleKey)
        if (owner == null) editor.remove(keyPreSosOwner) else editor.putString(keyPreSosOwner, owner)
        if (startedAt == null) editor.remove(keyPreSosStartedAt) else editor.putLong(keyPreSosStartedAt, startedAt)
        if (expectedActivationAt == null) {
            editor.remove(keyPreSosExpectedActivationAt)
        } else {
            editor.putLong(keyPreSosExpectedActivationAt, expectedActivationAt)
        }
        if (originatorNodeId == null) {
            editor.remove(keyPreSosOriginatorNodeId)
        } else {
            editor.putInt(keyPreSosOriginatorNodeId, originatorNodeId)
        }
        if (packetId == null) {
            editor.remove(keyPreSosPacketId)
        } else {
            editor.putInt(keyPreSosPacketId, packetId)
        }
        editor.apply()
    }

    fun clearPreSosLifecycle() {
        preferences.edit()
            .putString(keyPreSosLifecycleState, "idle")
            .putString(keyPendingSosState, "idle")
            .remove(keyPreSosCycleKey)
            .remove(keyPreSosOwner)
            .remove(keyPreSosStartedAt)
            .remove(keyPreSosExpectedActivationAt)
            .remove(keyPreSosOriginatorNodeId)
            .remove(keyPreSosPacketId)
            .apply()
    }

    fun hasPendingNativeSosCreate(): Boolean =
        preferences.getInt(keyPendingNativeSosCreateCount, 0) > 0

    fun hasPendingNativeSosCancel(): Boolean =
        preferences.getInt(keyPendingNativeSosCancelCount, 0) > 0

    fun currentApiBaseUrl(): String? =
        preferences.getString(keyApiBaseUrl, null)

    fun saveApiBaseUrl(value: String?) {
        preferences.edit().putString(keyApiBaseUrl, value).apply()
    }

    fun markBackendIncidentActive(
        incidentId: String?,
        incidentState: String?,
    ) {
        preferences.edit()
            .putString(keyActiveBackendIncidentId, incidentId)
            .putString(keyActiveBackendIncidentState, incidentState)
            .putLong(keyActiveBackendIncidentAt, System.currentTimeMillis())
            .putString(keyLastNativeBackendHandoffResult, "create_synced")
            .remove(keyLastNativeBackendHandoffError)
            .apply()
    }

    fun markBackendIncidentCleared(result: String = "cancel_synced") {
        preferences.edit()
            .remove(keyActiveBackendIncidentId)
            .remove(keyActiveBackendIncidentState)
            .remove(keyActiveBackendIncidentAt)
            .putString(keyLastNativeBackendHandoffResult, result)
            .putString(keyPreSosLifecycleState, "idle")
            .putString(keyPendingSosState, "idle")
            .remove(keyPreSosCycleKey)
            .remove(keyPreSosOwner)
            .remove(keyPreSosStartedAt)
            .remove(keyPreSosExpectedActivationAt)
            .remove(keyPreSosOriginatorNodeId)
            .remove(keyPreSosPacketId)
            .remove(keyLastNativeBackendHandoffError)
            .apply()
    }

    fun activeBackendIncidentId(): String? =
        preferences.getString(keyActiveBackendIncidentId, null)

    fun lastBackendIncidentState(): String? =
        preferences.getString(keyActiveBackendIncidentState, null)

    fun markBackendHandoffQueued(result: String) {
        preferences.edit()
            .putString(keyLastNativeBackendHandoffResult, result)
            .apply()
    }

    fun markBackendHandoffFailure(error: String) {
        preferences.edit()
            .putString(keyLastNativeBackendHandoffError, error)
            .apply()
    }

    fun markBackendHandoffSuccess(result: String) {
        preferences.edit()
            .putString(keyLastNativeBackendHandoffResult, result)
            .remove(keyLastNativeBackendHandoffError)
            .apply()
    }

    fun recordEvent(
        type: String,
        reason: String?,
        isBleEvent: Boolean = false,
    ) {
        val now = System.currentTimeMillis()
        val editor = preferences.edit()
            .putString(keyLastPlatformEvent, type)
            .putLong(keyLastPlatformEventAt, now)
        if (reason != null) {
            editor.putString(keyLastWakeReason, reason)
        }
        if (type == "runtimeStarted" || type == "runtimeRestarted" || type == "runtimeRecovered") {
            editor.putLong(keyLastWakeAt, now)
        }
        if (isBleEvent) {
            editor
                .putString(keyLastBleServiceEvent, type)
                .putLong(keyLastBleServiceEventAt, now)
        }
        when (type) {
            "serviceStarted",
            "serviceRestarted",
            -> editor
                .putBoolean(keyServiceRunning, true)
                .putString(keyBleOwner, "androidService")
            "restorationDetected",
            "restorationRehydrated",
            -> editor
                .putString(keyLastRestorationEvent, type)
                .putLong(keyLastRestorationEventAt, now)
            "runtimeStarting" -> editor
                .putBoolean(keyServiceRunning, true)
                .putBoolean(keyRuntimeActive, true)
                .putString(keyBleOwner, "androidService")
                .putString(keyReadinessFailureReason, null)
                .putString(
                    keyDegradationReason,
                    "Android foreground service owns the Protection Mode runtime, but the service-owned BLE link is not connected yet.",
                )
            "runtimeStarted",
            "runtimeActive",
            "runtimeRecovered",
            "runtimeRestarted",
            -> editor
                .putBoolean(keyServiceRunning, true)
                .putBoolean(keyRuntimeActive, true)
                .putString(keyBleOwner, "androidService")
            "deviceConnecting" -> editor
                .putBoolean(keyRuntimeActive, true)
                .putString(
                    keyDegradationReason,
                    "Android foreground service is reconnecting to the protected BLE device.",
                )
                .putString(
                    keyReadinessFailureReason,
                    "Android foreground service is reconnecting to the protected BLE device.",
                )
            "deviceConnected" -> editor.putBoolean(keyServiceBleConnected, true)
            "deviceDisconnected" -> editor
                .putBoolean(keyServiceBleConnected, false)
                .putBoolean(keyServiceBleReady, false)
                .putString(
                    keyReadinessFailureReason,
                    "Android foreground service is reconnecting to the protected BLE device.",
                )
                .putString(
                    keyDegradationReason,
                    "Android foreground service is reconnecting to the protected BLE device.",
                )
            "subscriptionsActive" -> editor
                .putBoolean(keyServiceBleConnected, true)
                .putBoolean(keyServiceBleReady, true)
                .putString(keyReadinessFailureReason, null)
                .putString(keyDegradationReason, null)
            "reconnectScheduled",
            "reconnectFailed",
            -> {
                val nextAttempt =
                    preferences.getInt(keyReconnectAttemptCount, 0) + 1
                editor
                    .putInt(keyReconnectAttemptCount, nextAttempt)
                    .putLong(keyLastReconnectAttemptAt, now)
                    .putString(
                        keyDegradationReason,
                        "Android foreground service is reconnecting to the protected BLE device.",
                    )
                    .putString(
                        keyReadinessFailureReason,
                        "Android foreground service is reconnecting to the protected BLE device.",
                    )
            }
            "runtimeError",
            "runtimeFailed",
            -> editor
                .putBoolean(keyRuntimeActive, false)
                .putString(keyDegradationReason, reason ?: preferences.getString(keyLastFailureReason, null))
            "runtimeStopped",
            "serviceStopped",
            -> editor
                .putBoolean(keyServiceRunning, false)
                .putBoolean(keyRuntimeActive, false)
                .putString(keyBleOwner, "flutter")
                .putBoolean(keyServiceBleConnected, false)
                .putBoolean(keyServiceBleReady, false)
                .putString(keyReadinessFailureReason, null)
                .putString(keyDegradationReason, null)
        }
        editor.apply()
    }

    private fun currentDegradationReason(): String? {
        val serviceRunning = preferences.getBoolean(keyServiceRunning, false)
        val runtimeActive = preferences.getBoolean(keyRuntimeActive, false)
        val serviceBleConnected = preferences.getBoolean(keyServiceBleConnected, false)
        val serviceBleReady = preferences.getBoolean(keyServiceBleReady, false)
        val lastFailureReason = preferences.getString(keyLastFailureReason, null)
        val storedReason = preferences.getString(keyDegradationReason, null)
        val nativeBackendConfigValid = preferences.getBoolean(keyNativeBackendConfigValid, true)
        val nativeBackendConfigIssue = preferences.getString(keyNativeBackendConfigIssue, null)
        return when {
            !serviceRunning -> null
            !runtimeActive -> lastFailureReason
                ?: storedReason
                ?: "Android foreground service is running, but the Protection runtime is not active."
            !nativeBackendConfigValid -> nativeBackendConfigIssue
                ?: storedReason
            !serviceBleConnected -> storedReason
                ?: "Android foreground service is running, but the service-owned BLE link is not connected yet."
            !serviceBleReady -> storedReason
                ?: "Android foreground service connected to the protected device, but TEL/SOS subscriptions are not active yet."
            else -> null
        }
    }

    fun flushQueues(): Map<String, Any> {
        val flushedSosCount = preferences.getInt(keyPendingSosCount, 0)
        val flushedTelemetryCount = preferences.getInt(keyPendingTelemetryCount, 0)
        preferences.edit()
            .putInt(keyPendingSosCount, 0)
            .putInt(keyPendingNativeSosCreateCount, 0)
            .putInt(keyPendingNativeSosCancelCount, 0)
            .putInt(keyPendingTelemetryCount, 0)
            .apply()
        return mapOf(
            "flushedSosCount" to flushedSosCount,
            "flushedTelemetryCount" to flushedTelemetryCount,
            "success" to true,
        )
    }

    companion object {
        private const val prefsName = "eixam_protection_runtime"
        private const val keyServiceRunning = "service_running"
        private const val keyRuntimeActive = "runtime_active"
        private const val keyBleOwner = "ble_owner"
        private const val keyServiceBleConnected = "service_ble_connected"
        private const val keyServiceBleReady = "service_ble_ready"
        private const val keyTargetDeviceId = "target_device_id"
        private const val keyBackendHardwareId = "backend_hardware_id"
        private const val keyBleHardwareId = "ble_hardware_id"
        private const val keyFirmwareVersion = "firmware_version"
        private const val keyHardwareModel = "hardware_model"
        private const val keyBoundDeviceId = "bound_device_id"
        private const val keyBoundNodeId = "bound_node_id"
        private const val keyStoreAndForwardEnabled = "store_and_forward_enabled"
        private const val keyHostAppManagedNotifications = "host_app_managed_notifications"
        private const val keyProtectionModeTitle = "notification_protection_mode_title"
        private const val keyProtectionModeBody = "notification_protection_mode_body"
        private const val keyProtectionModeChannelName = "notification_protection_mode_channel_name"
        private const val keyProtectionModeChannelDescription =
            "notification_protection_mode_channel_description"
        private const val keyProtectionSosChannelName = "notification_protection_sos_channel_name"
        private const val keyProtectionSosChannelDescription =
            "notification_protection_sos_channel_description"
        private const val keyProtectionPreSosTitle = "notification_protection_pre_sos_title"
        private const val keyProtectionPreSosBody = "notification_protection_pre_sos_body"
        private const val keyProtectionSosActiveTitle = "notification_protection_sos_active_title"
        private const val keyProtectionSosActiveBody = "notification_protection_sos_active_body"
        private const val keyProtectionSosResolvedTitle =
            "notification_protection_sos_resolved_title"
        private const val keyProtectionSosResolvedBody =
            "notification_protection_sos_resolved_body"
        private const val keyPendingSosCount = "pending_sos_count"
        private const val keyPendingSosState = "pending_sos_state"
        private const val keyPendingTelemetryCount = "pending_telemetry_count"
        private const val keyPendingNativeSosCreateCount = "pending_native_sos_create_count"
        private const val keyPendingNativeSosCancelCount = "pending_native_sos_cancel_count"
        private const val keyPendingExternalRelayCancels = "pending_external_relay_cancels"
        private const val keyReconnectAttemptCount = "reconnect_attempt_count"
        private const val keyLastReconnectAttemptAt = "last_reconnect_attempt_at"
        private const val keyReconnectBackoffMs = "reconnect_backoff_ms"
        private const val keyLastFailureReason = "last_failure_reason"
        private const val keyLastWakeReason = "last_wake_reason"
        private const val keyLastWakeAt = "last_wake_at"
        private const val keyLastPacketHex = "last_packet_hex"
        private const val keyLastPacketAt = "last_packet_at"
        private const val keyLastRestorationEvent = "last_restoration_event"
        private const val keyLastRestorationEventAt = "last_restoration_event_at"
        private const val keyLastPlatformEvent = "last_platform_event"
        private const val keyLastPlatformEventAt = "last_platform_event_at"
        private const val keyLastBleServiceEvent = "last_ble_service_event"
        private const val keyLastBleServiceEventAt = "last_ble_service_event_at"
        private const val keyBackgroundCapabilityState = "background_capability_state"
        private const val keyDegradationReason = "degradation_reason"
        private const val keyExpectedBleServiceUuid = "expected_ble_service_uuid"
        private const val keyExpectedBleCharacteristicUuids = "expected_ble_characteristic_uuids"
        private const val keyDiscoveredBleServicesSummary = "discovered_ble_services_summary"
        private const val keyReadinessFailureReason = "readiness_failure_reason"
        private const val keyApiBaseUrl = "api_base_url"
        private const val keyNativeBackendConfigValid = "native_backend_config_valid"
        private const val keyNativeBackendConfigIssue = "native_backend_config_issue"
        private const val keyDebugLocalhostBackendAllowed = "debug_localhost_backend_allowed"
        private const val keyDebugCleartextBackendAllowed = "debug_cleartext_backend_allowed"
        private const val keyActiveBackendIncidentId = "active_backend_incident_id"
        private const val keyActiveBackendIncidentState = "active_backend_incident_state"
        private const val keyActiveBackendIncidentAt = "active_backend_incident_at"
        private const val keyLastNativeBackendHandoffResult = "last_native_backend_handoff_result"
        private const val keyLastNativeBackendHandoffError = "last_native_backend_handoff_error"
        private const val keyLastCommandRoute = "last_command_route"
        private const val keyLastCommandResult = "last_command_result"
        private const val keyLastCommandError = "last_command_error"
        private const val keyPreSosLifecycleState = "pre_sos_lifecycle_state"
        private const val keyPreSosCycleKey = "pre_sos_cycle_key"
        private const val keyPreSosOwner = "pre_sos_owner"
        private const val keyPreSosStartedAt = "pre_sos_started_at"
        private const val keyPreSosExpectedActivationAt = "pre_sos_expected_activation_at"
        private const val keyPreSosOriginatorNodeId = "pre_sos_originator_node_id"
        private const val keyPreSosPacketId = "pre_sos_packet_id"
        private const val expectedBleServiceUuid = "6ba1b218-15a8-461f-9fa8-5dcae273ea00"
        private val expectedBleCharacteristicUuids = listOf(
            "6ba1b218-15a8-461f-9fa8-5dcae273ea01",
            "6ba1b218-15a8-461f-9fa8-5dcae273ea02",
            "6ba1b218-15a8-461f-9fa8-5dcae273ea03",
            "6ba1b218-15a8-461f-9fa8-5dcae273ea04",
        )
    }
}

private fun android.content.SharedPreferences.getIntOrNull(key: String): Int? =
    if (contains(key)) getInt(key, 0) else null

private fun JSONObject.optNullableString(key: String): String? =
    if (has(key) && !isNull(key)) optString(key).trim().takeIf { it.isNotBlank() } else null

private fun android.content.SharedPreferences.Editor.putNotificationText(
    preferenceKey: String,
    notificationTexts: Map<*, *>?,
    textKey: String,
): android.content.SharedPreferences.Editor {
    val value = (notificationTexts?.get(textKey) as? String)
        ?.trim()
        ?.takeIf { it.isNotBlank() }
    return if (value == null) remove(preferenceKey) else putString(preferenceKey, value)
}
