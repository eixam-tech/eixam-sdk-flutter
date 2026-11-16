package dev.eixam.connect.flutter.protection

import org.junit.Assert.assertEquals
import org.junit.Test

class ProtectionPlatformEventBufferTest {
    @Test
    fun `first START and following CANCEL survive listener handoff in order`() {
        val buffer = ProtectionPlatformEventBuffer(capacity = 4)
        buffer.add(mapOf("type" to "bleNotificationReceived", "payloadHex" to "start"))
        buffer.add(mapOf("type" to "ownDeviceSosLifecycleObserved", "payloadHex" to "start"))
        buffer.add(mapOf("type" to "bleNotificationReceived", "payloadHex" to "cancel"))
        buffer.add(mapOf("type" to "ownDeviceSosLifecycleObserved", "payloadHex" to "cancel"))

        val drained = mutableListOf<Map<String, Any?>>()
        buffer.drain(drained::add)

        assertEquals(
            listOf(
                "bleNotificationReceived:start",
                "ownDeviceSosLifecycleObserved:start",
                "bleNotificationReceived:cancel",
                "ownDeviceSosLifecycleObserved:cancel",
            ),
            drained.map { "${it["type"]}:${it["payloadHex"]}" },
        )
    }

    @Test
    fun `bounded buffer preserves newest complete handoff evidence`() {
        val buffer = ProtectionPlatformEventBuffer(capacity = 2)
        buffer.add(mapOf("receiveSequence" to 1))
        buffer.add(mapOf("receiveSequence" to 2))
        buffer.add(mapOf("receiveSequence" to 3))

        val drained = mutableListOf<Map<String, Any?>>()
        buffer.drain(drained::add)

        assertEquals(listOf(2, 3), drained.map { it["receiveSequence"] })
    }

    /**
     * F17c M-A: a stale-SOS stop request is only valid for the guard state at
     * the moment native decided. Replayed to a listener that attaches later,
     * it could stop a genuine new SOS the TAG started meanwhile: never buffered.
     */
    @Test
    fun `stale sos stop request is never buffered for a later listener`() {
        val buffer = ProtectionPlatformEventBuffer(capacity = 4)
        buffer.add(mapOf("type" to "ownDeviceSosLifecycleObserved", "payloadHex" to "start"))
        buffer.add(mapOf("type" to "ownTagSosStopRequired", "reason" to "cancel"))
        buffer.add(mapOf("type" to "bleNotificationReceived", "payloadHex" to "start"))

        val drained = mutableListOf<Map<String, Any?>>()
        buffer.drain(drained::add)

        assertEquals(
            listOf("ownDeviceSosLifecycleObserved", "bleNotificationReceived"),
            drained.map { it["type"] },
        )
    }
}
