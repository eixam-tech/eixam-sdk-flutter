package dev.eixam.connect.flutter.protection

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TelAggregateReassemblerTest {
    @Test
    fun `reassembles nearby 0xD8 from 0xD0 fragments`() {
        val blob = nearbyRxBlob(from = 0x12345678, text = "ok")
        val reassembler = TelAggregateReassembler()
        val first = d0Fragment(blob, offset = 0, length = 15)
        val second = d0Fragment(blob, offset = 15, length = blob.size - 15)

        assertNull(reassembler.ingest(first))
        val assembled = reassembler.ingest(second)
        assertEquals(blob, assembled)
        val parsed = NearbyTextNotifyParser.tryParse(assembled!!)
        assertEquals("ok", parsed?.text)
        assertEquals("EIXAM_12345678", parsed?.hardwareLabel)
    }

    @Test
    fun `passes unfragmented nearby 0xD8 through`() {
        val blob = nearbyRxBlob(text = "hi")
        assertEquals(blob, TelAggregateReassembler().ingest(blob))
    }

    @Test
    fun `reassembles 1-byte DM whose last D0 fragment is SOS length 13`() {
        val blob = nearbyRxBlob(from = 3, dest = 1, text = "a")
        val reassembler = TelAggregateReassembler()
        val first = d0Fragment(blob, offset = 0, length = 15)
        val second = d0Fragment(blob, offset = 15, length = blob.size - 15)

        assertEquals(13, second.size)
        assertNull(reassembler.ingest(first))
        val assembled = reassembler.ingest(second)
        assertEquals(blob, assembled)
        assertEquals("a", NearbyTextNotifyParser.tryParse(assembled!!)?.text)
        assertEquals("dm:00000003", NearbyTextNotifyParser.tryParse(assembled)?.threadKey)
    }

    @Test
    fun `reassembles 6-byte DM whose last D0 fragment is SOS length 18`() {
        val blob = nearbyRxBlob(from = 3, dest = 1, text = "hello!")
        val reassembler = TelAggregateReassembler()
        val first = d0Fragment(blob, offset = 0, length = 15)
        val second = d0Fragment(blob, offset = 15, length = blob.size - 15)

        assertEquals(18, second.size)
        assertNull(reassembler.ingest(first))
        val assembled = reassembler.ingest(second)
        assertEquals(blob, assembled)
        assertEquals("hello!", NearbyTextNotifyParser.tryParse(assembled!!)?.text)
    }

    @Test
    fun `does not treat GPS D0 as nearby text`() {
        val reassembler = TelAggregateReassembler()
        val first = listOf(0xD0, 6, 0, 0, 0, 0x10, 0x11, 0x12)
        val second = listOf(0xD0, 6, 0, 3, 0, 0x13, 0x14, 0x15)
        assertNull(reassembler.ingest(first))
        val assembled = reassembler.ingest(second)
        assertEquals(listOf(0x10, 0x11, 0x12, 0x13, 0x14, 0x15), assembled)
        assertNull(NearbyTextNotifyParser.tryParse(assembled!!))
    }

    private fun d0Fragment(blob: List<Int>, offset: Int, length: Int): List<Int> {
        val chunk = blob.subList(offset, offset + length)
        return listOf(
            0xD0,
            blob.size and 0xFF,
            (blob.size shr 8) and 0xFF,
            offset and 0xFF,
            (offset shr 8) and 0xFF,
        ) + chunk
    }

    private fun nearbyRxBlob(
        from: Int = 0x12345678,
        dest: Int = -1,
        packetId: Int = 8,
        text: String,
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
            0, 0, 0, 0, 0, 0, 0, 0,
            0,
        ) + utf8
    }
}
