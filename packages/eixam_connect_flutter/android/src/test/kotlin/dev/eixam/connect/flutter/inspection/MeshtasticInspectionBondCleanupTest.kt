package dev.eixam.connect.flutter.inspection

import android.bluetooth.BluetoothDevice
import org.junit.Assert.*
import org.junit.Test

class MeshtasticInspectionBondCleanupTest {
    @Test fun establishedBondIsPreserved() {
        var cancellations = 0
        assertFalse(cancelUnfinishedBond({ BluetoothDevice.BOND_BONDED }, { cancellations++; true }))
        assertEquals(0, cancellations)
    }
    @Test fun absentBondIsUntouched() {
        var cancellations = 0
        assertFalse(cancelUnfinishedBond({ BluetoothDevice.BOND_NONE }, { cancellations++; true }))
        assertEquals(0, cancellations)
    }
    @Test fun pendingCancellationWaitsForSettlement() {
        assertTrue(cancelUnfinishedBond({ BluetoothDevice.BOND_BONDING }, { true }))
    }
    @Test fun immediateSettlementNeedsNoBroadcastWait() {
        var state = BluetoothDevice.BOND_BONDING
        assertFalse(cancelUnfinishedBond({ state }, { state = BluetoothDevice.BOND_NONE; true }))
    }
    @Test(expected = IllegalStateException::class) fun rejectedCancellationDoesNotReportCleanupSuccess() {
        cancelUnfinishedBond({ BluetoothDevice.BOND_BONDING }, { false })
    }
}
