package dev.eixam.connect.flutter.protection

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtectionBleSosIdentityClassifierTest {
    @Test
    fun `own-device SOS payload is classified as local`() {
        val classification = ProtectionBleSosIdentityClassifier.classify(
            payload = listOf(0x34, 0x12, 0x00, 0x00, 0x00, 0x40, 0x09),
            connectedNodeId = 0x1234,
            source = ProtectionBleSosRelaySource.sos,
        )

        assertEquals(ProtectionBleSosIdentityClassification.OwnSos, classification)
    }

    @Test
    fun `remote SOS notify is classified as relay with originator and relay ids`() {
        val classification = ProtectionBleSosIdentityClassifier.classify(
            payload = listOf(0x78, 0x56, 0x34, 0x12, 0x00, 0x40, 0x09),
            connectedNodeId = 0x1234,
            source = ProtectionBleSosRelaySource.sos,
        )

        assertTrue(classification is ProtectionBleSosIdentityClassification.RemoteSos)
        val remote = classification as ProtectionBleSosIdentityClassification.RemoteSos
        assertEquals(0x12345678, remote.originatorNodeId)
        assertEquals(0x1234, remote.relayNodeId)
        assertEquals(ProtectionBleSosRelaySource.sos, remote.source)
    }

    @Test
    fun `valid SOS with unknown connected node is not classified as own-device`() {
        val classification = ProtectionBleSosIdentityClassifier.classify(
            payload = listOf(0x78, 0x56, 0x34, 0x12, 0x00, 0x40, 0x09),
            connectedNodeId = null,
            source = ProtectionBleSosRelaySource.sos,
        )

        assertTrue(classification is ProtectionBleSosIdentityClassification.UnknownOriginSos)
        val unknown = classification as ProtectionBleSosIdentityClassification.UnknownOriginSos
        assertEquals(0x12345678, unknown.originatorNodeId)
        assertEquals(ProtectionBleSosRelaySource.sos, unknown.source)
    }

    @Test
    fun `bound node fallback does not prove own-device SOS when connected node is unavailable`() {
        val classification = ProtectionBleSosIdentityClassifier.classify(
            payload = listOf(0x78, 0x56, 0x34, 0x12, 0x00, 0x40, 0x09),
            connectedNodeId = null,
            boundNodeId = 0x12345678,
            source = ProtectionBleSosRelaySource.sos,
        )
        val route = ProtectionBleSosNativeRouting.route(classification)

        assertFalse(classification == ProtectionBleSosIdentityClassification.OwnSos)
        assertFalse(classification == ProtectionBleSosIdentityClassification.OwnEvent)
        assertTrue(classification is ProtectionBleSosIdentityClassification.UnknownOriginSos)
        assertFalse(route.observeLocalLifecycle)
    }

    @Test
    fun `unknown LoRa SOS stays unknown when no connected or bound node matches`() {
        val classification = ProtectionBleSosIdentityClassifier.classify(
            payload = listOf(0x78, 0x56, 0x34, 0x12, 0x00, 0x40, 0x09),
            connectedNodeId = null,
            boundNodeId = null,
            source = ProtectionBleSosRelaySource.sos,
        )

        assertTrue(classification is ProtectionBleSosIdentityClassification.UnknownOriginSos)
        val unknown = classification as ProtectionBleSosIdentityClassification.UnknownOriginSos
        assertEquals(0x12345678, unknown.originatorNodeId)
    }

    @Test
    fun `SOS with unknown connected node stays held even when bound node differs`() {
        val classification = ProtectionBleSosIdentityClassifier.classify(
            payload = listOf(0x78, 0x56, 0x34, 0x12, 0x00, 0x40, 0x09),
            connectedNodeId = null,
            boundNodeId = 0x1234,
            source = ProtectionBleSosRelaySource.sos,
        )

        assertTrue(classification is ProtectionBleSosIdentityClassification.UnknownOriginSos)
        val unknown = classification as ProtectionBleSosIdentityClassification.UnknownOriginSos
        assertEquals(0x12345678, unknown.originatorNodeId)
    }

    @Test
    fun `valid TEL SOS with unknown connected node is not classified as TEL or own-device`() {
        val classification = ProtectionBleSosIdentityClassifier.classify(
            payload = listOf(
                0x78,
                0x56,
                0x34,
                0x12,
                0x48,
                0xCD,
                0x1B,
                0x34,
                0x44,
                0x28,
                0x00,
                0x40,
            ),
            connectedNodeId = null,
            source = ProtectionBleSosRelaySource.tel,
        )

        assertTrue(classification is ProtectionBleSosIdentityClassification.UnknownOriginSos)
        val unknown = classification as ProtectionBleSosIdentityClassification.UnknownOriginSos
        assertEquals(0x12345678, unknown.originatorNodeId)
        assertEquals(ProtectionBleSosRelaySource.tel, unknown.source)
    }

    @Test
    fun `remote 12-byte TEL SOS is classified as relay before TEL position`() {
        val classification = ProtectionBleSosIdentityClassifier.classify(
            payload = listOf(
                0x78,
                0x56,
                0x34,
                0x12,
                0x48,
                0xCD,
                0x1B,
                0x34,
                0x44,
                0x28,
                0x00,
                0x40,
            ),
            connectedNodeId = 0x1234,
            source = ProtectionBleSosRelaySource.tel,
        )

        assertTrue(classification is ProtectionBleSosIdentityClassification.RemoteSos)
        val remote = classification as ProtectionBleSosIdentityClassification.RemoteSos
        assertEquals(0x12345678, remote.originatorNodeId)
        assertEquals(0x1234, remote.relayNodeId)
        assertEquals(ProtectionBleSosRelaySource.tel, remote.source)
    }

    @Test
    fun `remote E1 02 event is classified as remote relay event`() {
        val classification = ProtectionBleSosIdentityClassifier.classify(
            payload = listOf(0xE1, 0x02, 0x78, 0x56, 0x34, 0x12),
            connectedNodeId = 0x1234,
            source = ProtectionBleSosRelaySource.sos,
        )

        assertTrue(classification is ProtectionBleSosIdentityClassification.RemoteEvent)
        val remote = classification as ProtectionBleSosIdentityClassification.RemoteEvent
        assertEquals(0x12345678, remote.originatorNodeId)
        assertEquals(0x1234, remote.relayNodeId)
    }

    @Test
    fun `local E1 02 event remains own-device event`() {
        val classification = ProtectionBleSosIdentityClassifier.classify(
            payload = listOf(0xE1, 0x02, 0x34, 0x12, 0x00, 0x00),
            connectedNodeId = 0x1234,
            source = ProtectionBleSosRelaySource.sos,
        )

        assertEquals(ProtectionBleSosIdentityClassification.OwnEvent, classification)
    }

    @Test
    fun `own-device SOS observes local lifecycle without emitting sosEventReceived`() {
        val classification = ProtectionBleSosIdentityClassifier.classify(
            payload = listOf(0x34, 0x12, 0x00, 0x00, 0x00, 0x80, 0x09),
            connectedNodeId = 0x1234,
            source = ProtectionBleSosRelaySource.sos,
        )
        val route = ProtectionBleSosNativeRouting.route(classification)

        assertEquals(ProtectionBleSosIdentityClassification.OwnSos, classification)
        assertTrue(route.observeLocalLifecycle)
        assertFalse(route.emitSosEventReceived)
        assertEquals("ownDeviceSosLifecycleObserved", route.diagnosticEventType)
    }

    @Test
    fun `remote relay SOS still emits sosEventReceived`() {
        val classification = ProtectionBleSosIdentityClassifier.classify(
            payload = listOf(0x78, 0x56, 0x34, 0x12, 0x00, 0x80, 0x09),
            connectedNodeId = 0x1234,
            source = ProtectionBleSosRelaySource.sos,
        )
        val route = ProtectionBleSosNativeRouting.route(classification)

        assertTrue(classification is ProtectionBleSosIdentityClassification.RemoteSos)
        assertFalse(route.observeLocalLifecycle)
        assertTrue(route.emitSosEventReceived)
    }

    @Test
    fun `unknown origin SOS still emits sosEventReceived`() {
        val classification = ProtectionBleSosIdentityClassifier.classify(
            payload = listOf(0x78, 0x56, 0x34, 0x12, 0x00, 0x80, 0x09),
            connectedNodeId = null,
            boundNodeId = null,
            source = ProtectionBleSosRelaySource.sos,
        )
        val route = ProtectionBleSosNativeRouting.route(classification)

        assertTrue(classification is ProtectionBleSosIdentityClassification.UnknownOriginSos)
        assertFalse(route.observeLocalLifecycle)
        assertTrue(route.emitSosEventReceived)
    }

    @Test
    fun `local E1 02 event does not use bound node fallback`() {
        val classification = ProtectionBleSosIdentityClassifier.classify(
            payload = listOf(0xE1, 0x02, 0x78, 0x56, 0x34, 0x12),
            connectedNodeId = null,
            boundNodeId = 0x12345678,
            source = ProtectionBleSosRelaySource.sos,
        )
        val route = ProtectionBleSosNativeRouting.route(classification)

        assertFalse(classification == ProtectionBleSosIdentityClassification.OwnSos)
        assertFalse(classification == ProtectionBleSosIdentityClassification.OwnEvent)
        assertTrue(classification is ProtectionBleSosIdentityClassification.UnknownOriginEvent)
        assertFalse(route.observeLocalLifecycle)
    }

    @Test
    fun `E1 02 event without connected identity is held and emitted as remote candidate`() {
        val classification = ProtectionBleSosIdentityClassifier.classify(
            payload = listOf(0xE1, 0x02, 0x78, 0x56, 0x34, 0x12),
            connectedNodeId = null,
            boundNodeId = null,
            source = ProtectionBleSosRelaySource.sos,
        )
        val route = ProtectionBleSosNativeRouting.route(classification)

        assertTrue(classification is ProtectionBleSosIdentityClassification.UnknownOriginEvent)
        assertFalse(route.observeLocalLifecycle)
        assertTrue(route.emitSosEventReceived)
    }

    @Test
    fun `own-device SOS still uses local lifecycle when connected node is known`() {
        val classification = ProtectionBleSosIdentityClassifier.classify(
            payload = listOf(0x78, 0x56, 0x34, 0x12, 0x00, 0x80, 0x09),
            connectedNodeId = 0x12345678,
            boundNodeId = 0x12345678,
            source = ProtectionBleSosRelaySource.sos,
        )
        val route = ProtectionBleSosNativeRouting.route(classification)

        assertEquals(ProtectionBleSosIdentityClassification.OwnSos, classification)
        assertTrue(route.observeLocalLifecycle)
    }

    @Test
    fun `remote relay SOS remains remote when connected node differs from originator`() {
        val classification = ProtectionBleSosIdentityClassifier.classify(
            payload = listOf(0x78, 0x56, 0x34, 0x12, 0x00, 0x80, 0x09),
            connectedNodeId = 0x1234,
            boundNodeId = 0x1234,
            source = ProtectionBleSosRelaySource.sos,
        )
        val route = ProtectionBleSosNativeRouting.route(classification)

        assertTrue(classification is ProtectionBleSosIdentityClassification.RemoteSos)
        val remote = classification as ProtectionBleSosIdentityClassification.RemoteSos
        assertEquals(0x12345678, remote.originatorNodeId)
        assertEquals(0x1234, remote.relayNodeId)
        assertFalse(route.observeLocalLifecycle)
    }

    @Test
    fun `remote cancel with unknown connected node does not use bound node for local lifecycle`() {
        val classification = ProtectionBleSosIdentityClassifier.classify(
            payload = listOf(0xE1, 0x02, 0x78, 0x56, 0x34, 0x12),
            connectedNodeId = null,
            boundNodeId = 0x12345678,
            source = ProtectionBleSosRelaySource.sos,
        )
        val route = ProtectionBleSosNativeRouting.route(classification)

        assertTrue(classification is ProtectionBleSosIdentityClassification.UnknownOriginEvent)
        assertFalse(route.observeLocalLifecycle)
        assertTrue(route.emitSosEventReceived)
    }

    @Test
    fun `device runtime status exposes connected BLE node id`() {
        val nodeId = ProtectionBleSosIdentityClassifier.tryParseDeviceRuntimeNodeId(
            listOf(
                0xE9,
                0x78,
                0x02,
                0x00,
                0x00,
                0x00,
                0x00,
                0x34,
                0x12,
                0x00,
                0x00,
                0x55,
                0x3C,
                0x00,
            ),
        )

        assertEquals(0x1234, nodeId)
    }
}
