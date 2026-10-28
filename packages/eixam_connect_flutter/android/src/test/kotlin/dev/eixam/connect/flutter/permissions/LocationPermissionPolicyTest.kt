package dev.eixam.connect.flutter.permissions

import org.junit.Assert.*
import org.junit.Test
import dev.eixam.connect.flutter.permissions.LocationPermissionPolicy.Action

class LocationPermissionPolicyTest {
    @Test fun versionMappingNeverInventsBackgroundGrants() {
        for (api in listOf(23, 28, 29, 30, 31, 34, 36)) {
            assertFalse(LocationPermissionPolicy.backgroundGranted(api, false, true))
            assertEquals(api < 29, LocationPermissionPolicy.backgroundGranted(api, true, false))
            assertTrue(LocationPermissionPolicy.backgroundGranted(api, true, true))
        }
    }

    @Test fun foregroundAndBackgroundAreAlwaysIncremental() {
        assertEquals(Action.NONE, LocationPermissionPolicy.action(true, false, false, true, true))
        assertEquals(Action.FOREGROUND, LocationPermissionPolicy.action(false, false, false, true, true))
        assertEquals(Action.BACKGROUND, LocationPermissionPolicy.action(true, true, false, false, true))
    }

    @Test fun grantedPermissionsNeverReopenUi() {
        assertEquals(Action.NONE, LocationPermissionPolicy.action(false, true, false, false, true))
        assertEquals(Action.NONE, LocationPermissionPolicy.action(true, true, true, false, false))
    }

    @Test fun exhaustedNativeRequestUsesAppSettings() {
        assertEquals(Action.SETTINGS, LocationPermissionPolicy.action(true, true, false, false, false))
        assertEquals(Action.SETTINGS, LocationPermissionPolicy.action(false, false, false, false, false))
    }
}
