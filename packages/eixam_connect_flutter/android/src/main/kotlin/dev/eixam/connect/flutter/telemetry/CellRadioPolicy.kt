package dev.eixam.connect.flutter.telemetry

import android.telephony.TelephonyManager

internal data class CellRadioObservation(
    val networkType: Int?,
    val registered: Boolean,
    val timestampNanos: Long,
)

internal object CellRadioPolicy {
    // Coverage is a current location sample: at most ten seconds of modem cache
    // is acceptable. Prefer omission to retaining a previous radio environment.
    const val MAX_CELL_INFO_AGE_NANOS = 10_000_000_000L

    fun hint(
        activeSubscriptionIds: List<Int>?,
        cells: List<CellRadioObservation>,
        nowNanos: Long,
        authoritativeNetworkType: Int? = null,
        radioCount: Int?,
    ): CellRadioHint {
        val unknown = CellRadioHint(null, null)
        if (radioCount != 1) return unknown
        if (activeSubscriptionIds?.singleOrNull()?.takeIf { it >= 0 } == null) return unknown
        val types = cells.filter {
            it.registered && isFresh(it.timestampNanos, nowNanos)
        }.mapNotNull { it.networkType }.toSet()
        if (types.isEmpty()) return unknown
        if (types == setOf(TelephonyManager.NETWORK_TYPE_NR, TelephonyManager.NETWORK_TYPE_LTE)) {
            // Same confirmed subscription, both observations fresh. Literal NSA
            // override avoids loading the API 30 TelephonyDisplayInfo on API 21.
            return CellRadioHint(TelephonyManager.NETWORK_TYPE_LTE, 3)
        }
        // Conflicting registered generations cannot be resolved by priority.
        if (types.size != 1) return unknown
        val type = types.single()
        // Absence of a fresh LTE anchor does not prove SA (it may be stale or
        // missing). Require subscription-specific data RAT to corroborate NR.
        if (type == TelephonyManager.NETWORK_TYPE_NR && authoritativeNetworkType != type) return unknown
        return CellRadioHint(type, null)
    }

    internal fun isFresh(timestampNanos: Long, nowNanos: Long): Boolean {
        // Reject missing/sentinel, future and invalid clocks before subtraction.
        return timestampNanos > 0 && timestampNanos != Long.MAX_VALUE &&
            nowNanos >= timestampNanos && nowNanos - timestampNanos <= MAX_CELL_INFO_AGE_NANOS
    }
}
