package dev.eixam.connect.flutter.protection

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NearbyTextNotifyParserTest {
    @Test
    fun `parses plaza nearby text`() {
        val parsed = NearbyTextNotifyParser.tryParse(
            nearbyRxBlob(from = 0x12345678, text = "hi"),
        )

        requireNotNull(parsed)
        assertEquals(0x12345678, parsed.fromNodeId)
        assertEquals(-1, parsed.destNodeId)
        assertEquals(8, parsed.packetId)
        assertEquals(0L, parsed.groupId)
        assertEquals("hi", parsed.text)
        assertTrue(parsed.plaza)
        assertEquals("nearby", parsed.threadKey)
        assertEquals("EIXAM_12345678", parsed.hardwareLabel)
        assertEquals("nearby#nearby", parsed.payload)
    }

    @Test
    fun `parses direct message thread key`() {
        val parsed = NearbyTextNotifyParser.tryParse(
            nearbyRxBlob(
                from = 3,
                dest = 1,
                packetId = 9,
                text = "dm",
            ),
        )

        requireNotNull(parsed)
        assertEquals("dm:00000003", parsed.threadKey)
        assertEquals("nearby#dm:00000003", parsed.payload)
        assertEquals("3:9", parsed.dedupeKey)
    }

    @Test
    fun `parses group thread key`() {
        val parsed = NearbyTextNotifyParser.tryParse(
            nearbyRxBlob(
                from = 3,
                groupId = 0xAABBCCDDL,
                text = "group",
            ),
        )

        requireNotNull(parsed)
        assertEquals("grp:00000000aabbccdd", parsed.threadKey)
    }

    @Test
    fun `strips firmware length padding`() {
        val parsed = NearbyTextNotifyParser.tryParse(
            nearbyRxBlob(text = "ok", pad = 4),
        )

        assertEquals("ok", parsed?.text)
    }

    @Test
    fun `ignores tx status and reserved lengths`() {
        assertNull(NearbyTextNotifyParser.tryParse(listOf(0xDA, 0, 0, 0, 1, 0)))
        assertNull(NearbyTextNotifyParser.tryParse(List(7) { 0xD8 }))
        assertNull(NearbyTextNotifyParser.tryParse(listOf(0xDB, 1, 0, 0, 0, 0x41)))
    }

    private fun nearbyRxBlob(
        from: Int = 0x12345678,
        dest: Int = -1,
        packetId: Int = 8,
        groupId: Long = 0L,
        text: String,
        pad: Int = 0,
    ): List<Int> {
        val utf8 = text.toByteArray(Charsets.UTF_8).map { it.toInt() and 0xFF }
        return listOf(
            0xD8,
            from and 0xFF,
            (from ushr 8) and 0xFF,
            (from ushr 16) and 0xFF,
            (from ushr 24) and 0xFF,
            dest and 0xFF,
            (dest ushr 8) and 0xFF,
            (dest ushr 16) and 0xFF,
            (dest ushr 24) and 0xFF,
            packetId and 0xFF,
            (packetId ushr 8) and 0xFF,
            (packetId ushr 16) and 0xFF,
            (packetId ushr 24) and 0xFF,
            (groupId and 0xFF).toInt(),
            ((groupId ushr 8) and 0xFF).toInt(),
            ((groupId ushr 16) and 0xFF).toInt(),
            ((groupId ushr 24) and 0xFF).toInt(),
            ((groupId ushr 32) and 0xFF).toInt(),
            ((groupId ushr 40) and 0xFF).toInt(),
            ((groupId ushr 48) and 0xFF).toInt(),
            ((groupId ushr 56) and 0xFF).toInt(),
            0,
        ) + utf8 + List(pad) { 0xFF }
    }
}
