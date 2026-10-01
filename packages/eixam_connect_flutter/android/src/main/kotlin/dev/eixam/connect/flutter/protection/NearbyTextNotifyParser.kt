package dev.eixam.connect.flutter.protection

import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

internal data class NearbyTextNotify(
    val fromNodeId: Int,
    val destNodeId: Int,
    val packetId: Int,
    val groupId: Long,
    val text: String,
) {
    val plaza: Boolean
        get() = groupId == 0L && destNodeId.toUInt() == BROADCAST_DEST

    val threadKey: String
        get() = when {
            groupId != 0L -> "grp:" + groupId.toULong().toString(16).padStart(16, '0')
            destNodeId.toUInt() != BROADCAST_DEST ->
                "dm:" + fromNodeId.toUInt().toString(16).padStart(8, '0')
            else -> "nearby"
        }

    val hardwareLabel: String
        get() = "EIXAM_" + fromNodeId.toUInt().toString(16).padStart(8, '0').uppercase()

    val dedupeKey: String
        get() = "${fromNodeId.toUInt()}:${packetId.toUInt()}"

    val payload: String
        get() = "nearby#$threadKey"

    companion object {
        val BROADCAST_DEST: UInt = 0xFFFFFFFFu
    }
}

internal object NearbyTextNotifyParser {
    private const val opcode = 0xD8
    private const val headerLength = 22
    private const val maxPayloadBytes = 233
    private const val lengthPad = 0xFF

    fun tryParse(payload: List<Int>): NearbyTextNotify? {
        if (payload.size < headerLength || payload.first() != opcode) {
            return null
        }
        if (isReservedSosOrTelLength(payload.size)) {
            return null
        }
        val utf8 = stripPad(payload.subList(headerLength, payload.size))
        if (utf8.isEmpty() || utf8.size > maxPayloadBytes) {
            return null
        }
        val text = decodeUtf8(utf8) ?: return null
        return NearbyTextNotify(
            fromNodeId = u32le(payload, 1),
            destNodeId = u32le(payload, 5),
            packetId = u32le(payload, 9),
            groupId = u64le(payload, 13),
            text = text,
        )
    }

    private fun isReservedSosOrTelLength(length: Int): Boolean {
        return length == 6 ||
            length == 7 ||
            length == 10 ||
            length == 12 ||
            length == 13 ||
            length == 16 ||
            length == 18
    }

    private fun stripPad(bytes: List<Int>): List<Int> {
        var end = bytes.size
        while (end > 0 && bytes[end - 1] == lengthPad) {
            end--
        }
        return bytes.subList(0, end)
    }

    private fun decodeUtf8(bytes: List<Int>): String? {
        val raw = ByteArray(bytes.size) { index -> bytes[index].toByte() }
        return try {
            val decoder = StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
            decoder.decode(java.nio.ByteBuffer.wrap(raw)).toString()
        } catch (_: CharacterCodingException) {
            null
        }
    }

    private fun u32le(bytes: List<Int>, offset: Int): Int {
        return (bytes[offset] and 0xFF) or
            ((bytes[offset + 1] and 0xFF) shl 8) or
            ((bytes[offset + 2] and 0xFF) shl 16) or
            ((bytes[offset + 3] and 0xFF) shl 24)
    }

    private fun u64le(bytes: List<Int>, offset: Int): Long {
        val lo = u32le(bytes, offset).toUInt().toLong()
        val hi = u32le(bytes, offset + 4).toUInt().toLong()
        return (hi shl 32) or lo
    }
}
