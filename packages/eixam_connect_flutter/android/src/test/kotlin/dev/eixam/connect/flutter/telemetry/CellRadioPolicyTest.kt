package dev.eixam.connect.flutter.telemetry

import android.telephony.TelephonyManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CellRadioPolicyTest {
    private val now = 100_000_000_000L
    private val bound = CellRadioPolicy.MAX_CELL_INFO_AGE_NANOS
    private val unknown = CellRadioHint(null, null)
    private val lte = TelephonyManager.NETWORK_TYPE_LTE
    private val nr = TelephonyManager.NETWORK_TYPE_NR

    private fun cell(type: Int, age: Long = 0, registered: Boolean = true) =
        CellRadioObservation(type, registered, now - age)

    private fun hint(
        vararg cells: CellRadioObservation,
        subscriptions: List<Int>? = listOf(1),
        authoritativeNetworkType: Int? = null,
        radioCount: Int? = 1,
    ) = CellRadioPolicy.hint(subscriptions, cells.toList(), now, authoritativeNetworkType, radioCount)

    @Test fun `single subscription fresh NR and LTE is NSA`() {
        assertEquals(CellRadioHint(lte, 3), hint(cell(nr), cell(lte)))
    }

    @Test fun `NR on SIM A and LTE on SIM B cannot be NSA`() {
        // Android's global list carries no ownership; two active IDs are enough
        // to invalidate it, irrespective of the order or apparent generation.
        assertEquals(unknown, hint(cell(nr), cell(lte), subscriptions = listOf(1, 2)))
    }

    @Test fun `even matching generations on dual SIM are omitted`() {
        assertEquals(unknown, hint(cell(lte), cell(lte), subscriptions = listOf(1, 2)))
    }

    @Test fun `global cache on multi radio or unknown device is omitted even with one active SIM`() {
        for (count in listOf(null, 0, 2)) {
            assertEquals(unknown, hint(cell(nr), cell(lte), radioCount = count))
        }
    }

    @Test fun `single subscription LTE remains LTE`() {
        assertEquals(CellRadioHint(lte, null), hint(cell(lte)))
    }

    @Test fun `NR alone without authoritative RAT does not fabricate SA`() {
        assertEquals(unknown, hint(cell(nr)))
        assertEquals(unknown, hint(cell(nr), authoritativeNetworkType = lte))
    }

    @Test fun `single subscription authoritative NR preserves NR mapping`() {
        assertEquals(CellRadioHint(nr, null), hint(cell(nr), authoritativeNetworkType = nr))
    }

    @Test fun `neighbour LTE cannot turn NR into NSA`() {
        assertEquals(CellRadioHint(nr, null), hint(cell(nr), cell(lte, registered = false), authoritativeNetworkType = nr))
    }

    @Test fun `neighbour NR cannot turn LTE into NSA`() {
        assertEquals(CellRadioHint(lte, null), hint(cell(lte), cell(nr, registered = false)))
    }

    @Test fun `no registered observations are omitted`() {
        assertEquals(unknown, hint(cell(nr, registered = false)))
        assertEquals(unknown, hint())
    }

    @Test fun `unknown empty or invalid subscription ownership is omitted`() {
        for (ids in listOf(null, emptyList(), listOf(-1), listOf(1, 1))) {
            assertEquals(unknown, hint(cell(nr), cell(lte), subscriptions = ids))
        }
    }

    @Test fun `fresh observation accepted`() {
        assertTrue(CellRadioPolicy.isFresh(now, now))
        assertEquals(CellRadioHint(lte, null), hint(cell(lte)))
    }

    @Test fun `just inside and exactly at age bound accepted`() {
        assertEquals(CellRadioHint(lte, null), hint(cell(lte, bound - 1)))
        assertEquals(CellRadioHint(lte, null), hint(cell(lte, bound)))
    }

    @Test fun `one nanosecond beyond bound omitted`() {
        assertFalse(CellRadioPolicy.isFresh(now - bound - 1, now))
        assertEquals(unknown, hint(cell(lte, bound + 1)))
    }

    @Test fun `only fresh evidence participates`() {
        assertEquals(CellRadioHint(lte, null), hint(cell(lte), cell(TelephonyManager.NETWORK_TYPE_GSM, bound + 1)))
    }

    @Test fun `stale NR plus fresh LTE is not NSA`() {
        assertEquals(CellRadioHint(lte, null), hint(cell(nr, bound + 1), cell(lte)))
    }

    @Test fun `fresh NR plus stale LTE on same SIM is not NSA`() {
        assertEquals(unknown, hint(cell(nr), cell(lte, bound + 1)))
    }

    @Test fun `all stale observations omitted`() {
        assertEquals(unknown, hint(cell(nr, bound + 1), cell(lte, bound + 1)))
    }

    @Test fun `unavailable future and invalid timestamps omitted`() {
        for (timestamp in listOf(0L, -1L, Long.MIN_VALUE, Long.MAX_VALUE, now + 1)) {
            assertEquals(unknown, hint(CellRadioObservation(lte, true, timestamp)))
        }
        assertFalse(CellRadioPolicy.isFresh(1, -1))
    }

    @Test fun `conflicting unrelated registered generations omitted`() {
        assertEquals(unknown, hint(cell(lte), cell(TelephonyManager.NETWORK_TYPE_GSM)))
    }
}
