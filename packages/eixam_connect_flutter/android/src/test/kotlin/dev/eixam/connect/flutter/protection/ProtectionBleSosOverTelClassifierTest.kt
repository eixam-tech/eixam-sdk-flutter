package dev.eixam.connect.flutter.protection

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtectionBleSosOverTelClassifierTest {
    @Test
    fun `modern type-3 SOS is accepted before TEL fallback`() {
        val decision = ProtectionBleSosOverTelClassifier.classify(modernSos)

        assertEquals(ProtectionBleSosOverTelKind.ModernSos, decision.kind)
        assertEquals("modern_sos_type_3", decision.reason)
        assertEquals(3, decision.sosType)
        assertEquals(7, decision.packetId)
        assertEquals(0x12345678, decision.originatorNodeId)
        assertTrue(decision.isModernSos)
    }

    @Test
    fun `ordinary TEL format bit prevents false SOS`() {
        val tel = modernSos.toMutableList().apply {
            this[10] = 0x27
            this[11] = 0x85
        }
        val decision = ProtectionBleSosOverTelClassifier.classify(tel)

        assertEquals(ProtectionBleSosOverTelKind.Tel, decision.kind)
        assertEquals("tel_position_format_bit_set", decision.reason)
        assertFalse(decision.isModernSos)
    }

    @Test
    fun `legacy-looking payload stays TEL without hop proof`() {
        val legacy = modernSos.toMutableList().apply { this[11] = 0x40 }
        val decision = ProtectionBleSosOverTelClassifier.classify(legacy)

        assertEquals(ProtectionBleSosOverTelKind.Tel, decision.kind)
        assertEquals("legacy_or_non_sos_without_hop_proof", decision.reason)
        assertEquals(1, decision.sosType)
    }

    @Test
    fun `malformed byte domain fails closed`() {
        val malformed = modernSos.toMutableList().apply { this[4] = 0x100 }
        val decision = ProtectionBleSosOverTelClassifier.classify(malformed)

        assertEquals(ProtectionBleSosOverTelKind.Malformed, decision.kind)
        assertEquals("invalid_byte_domain", decision.reason)
    }

    private val modernSos = listOf(
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
        0x07,
        0xC0,
    )
}
