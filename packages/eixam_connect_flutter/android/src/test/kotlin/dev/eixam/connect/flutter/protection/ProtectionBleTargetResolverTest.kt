package dev.eixam.connect.flutter.protection

import org.junit.Assert.assertEquals
import org.junit.Test

class ProtectionBleTargetResolverTest {
    @Test
    fun `BLE hardware identity wins over backend active device identity`() {
        assertEquals(
            "DF:94:AF:46:94:56",
            resolveProtectionBleTarget(
                activeDeviceId = "E1:5F:27:D4:47:DB",
                bleHardwareId = " DF:94:AF:46:94:56 ",
            ),
        )
    }

    @Test
    fun `legacy active device identity remains a fallback`() {
        assertEquals(
            "E1:5F:27:D4:47:DB",
            resolveProtectionBleTarget(
                activeDeviceId = " E1:5F:27:D4:47:DB ",
                bleHardwareId = " ",
            ),
        )
    }
}
