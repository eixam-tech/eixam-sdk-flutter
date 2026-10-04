package dev.eixam.connect.flutter.dfu

import no.nordicsemi.android.dfu.DfuBaseService
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FirmwareDfuRecoveryClassificationTest {
    @Test fun observedGatt133AfterUploadRequiresRecovery() {
        assertTrue(uploadInterruptedByTransportFailure(true, 133, DfuBaseService.ERROR_TYPE_COMMUNICATION_STATE))
    }

    @Test fun communicationErrorAfterUploadRequiresRecovery() {
        assertTrue(uploadInterruptedByTransportFailure(true, 8, DfuBaseService.ERROR_TYPE_COMMUNICATION))
    }

    @Test fun bluetoothUnavailableAfterUploadRequiresRecovery() {
        assertTrue(uploadInterruptedByTransportFailure(true, DfuBaseService.ERROR_BLUETOOTH_DISABLED, DfuBaseService.ERROR_TYPE_OTHER))
    }

    @Test fun failureBeforeUploadDoesNotClaimErasedApplication() {
        assertFalse(uploadInterruptedByTransportFailure(false, 133, DfuBaseService.ERROR_TYPE_COMMUNICATION_STATE))
    }

    @Test fun remoteImageRejectionRemainsDistinct() {
        assertFalse(uploadInterruptedByTransportFailure(true, 6, DfuBaseService.ERROR_TYPE_DFU_REMOTE))
    }
}
