package dev.eixam.connect.flutter.protection

/**
 * Mirrors Dart [EixamTelFragment] / [EixamTelReassembler]. Nearby text is
 * 22 B header + UTF-8, so it always arrives as 0xD0 15-byte chunks on TEL.
 */
internal data class TelAggregateFragment(
    val totalLength: Int,
    val offset: Int,
    val fragmentPayload: List<Int>,
) {
    val fragmentLength: Int get() = fragmentPayload.size

    companion object {
        private const val opcode = 0xD0
        private const val headerLength = 5
        private const val maxPayloadLength = 15

        fun tryParse(bytes: List<Int>): TelAggregateFragment? {
            if (bytes.size < headerLength + 1 || bytes.first() != opcode) {
                return null
            }
            val totalLength = (bytes[1] and 0xFF) or ((bytes[2] and 0xFF) shl 8)
            val offset = (bytes[3] and 0xFF) or ((bytes[4] and 0xFF) shl 8)
            val payload = bytes.subList(headerLength, bytes.size)
            if (totalLength <= 0 || payload.isEmpty() || payload.size > maxPayloadLength) {
                return null
            }
            return TelAggregateFragment(totalLength, offset, payload.toList())
        }
    }
}

internal class TelAggregateReassembler {
    private var activeTotalLength: Int? = null
    private val fragmentsByOffset = linkedMapOf<Int, List<Int>>()

    fun ingest(payload: List<Int>): List<Int>? {
        val fragment = TelAggregateFragment.tryParse(payload) ?: return payload
        return addFragment(fragment)
    }

    fun addFragment(fragment: TelAggregateFragment): List<Int>? {
        if (fragment.offset < 0) {
            reset()
            return null
        }
        val active = activeTotalLength
        if (active == null) {
            activeTotalLength = fragment.totalLength
        } else if (active != fragment.totalLength) {
            reset()
            activeTotalLength = fragment.totalLength
        }
        val fragmentEnd = fragment.offset + fragment.fragmentLength
        if (fragmentEnd > fragment.totalLength) {
            reset()
            return null
        }
        for ((existingStart, existingPayload) in fragmentsByOffset) {
            val existingEnd = existingStart + existingPayload.size
            val overlaps = fragment.offset < existingEnd && fragmentEnd > existingStart
            if (!overlaps) {
                continue
            }
            val sameRange = existingStart == fragment.offset &&
                existingEnd == fragmentEnd &&
                existingPayload == fragment.fragmentPayload
            if (sameRange) {
                return tryComplete(fragment.totalLength)
            }
            reset()
            return null
        }
        fragmentsByOffset[fragment.offset] = fragment.fragmentPayload
        return tryComplete(fragment.totalLength)
    }

    fun reset() {
        activeTotalLength = null
        fragmentsByOffset.clear()
    }

    private fun tryComplete(totalLength: Int): List<Int>? {
        if (fragmentsByOffset.isEmpty()) {
            return null
        }
        val ordered = fragmentsByOffset.keys.sorted()
        var cursor = 0
        val completed = ArrayList<Int>(totalLength)
        for (offset in ordered) {
            if (offset != cursor) {
                return null
            }
            val payload = fragmentsByOffset[offset] ?: return null
            completed.addAll(payload)
            cursor += payload.size
        }
        if (cursor != totalLength) {
            return null
        }
        reset()
        return completed
    }
}
