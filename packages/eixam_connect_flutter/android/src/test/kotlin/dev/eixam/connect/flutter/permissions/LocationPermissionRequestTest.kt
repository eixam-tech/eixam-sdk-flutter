package dev.eixam.connect.flutter.permissions

import org.junit.Assert.*
import org.junit.Test

class LocationPermissionRequestTest {
    @Test fun settingsCompletesOnlyAfterHostHasPausedAndResumed() {
        val request = LocationPermissionRequest()
        val code = request.begin(settings = true)
        assertFalse(request.shouldCompleteOnResume())
        assertTrue(request.acceptsActivityResult(code))
        assertFalse(request.acceptsPermissionResult(code))
        request.onHostPaused()
        assertTrue(request.shouldCompleteOnResume())
        request.clear()
        assertFalse(request.shouldCompleteOnResume())
        assertFalse(request.acceptsActivityResult(code))
    }

    @Test fun lateSettingsResultCannotCompleteANewerPermissionOrSettingsRequest() {
        val request = LocationPermissionRequest()
        val oldCode = request.begin(settings = true)
        request.onHostPaused()
        assertTrue(request.shouldCompleteOnResume())
        request.clear() // Home/Recents return completed the old transaction.
        val foregroundCode = request.begin(settings = false)
        assertFalse(request.acceptsActivityResult(oldCode))
        assertFalse(request.acceptsPermissionResult(oldCode))
        assertTrue(request.acceptsPermissionResult(foregroundCode))
        request.onHostPaused()
        assertFalse(request.shouldCompleteOnResume())
        request.clear()
        val newSettingsCode = request.begin(settings = true)
        assertFalse(request.acceptsActivityResult(oldCode))
        assertTrue(request.acceptsActivityResult(newSettingsCode))
    }

    @Test fun detachRejectsResultsAndNewPluginInstanceUsesADifferentCode() {
        val old = LocationPermissionRequest()
        val oldCode = old.begin(settings = false)
        old.clear()
        assertFalse(old.acceptsPermissionResult(oldCode))
        val replacement = LocationPermissionRequest()
        val newCode = replacement.begin(settings = false)
        assertNotEquals(oldCode, newCode)
        assertFalse(replacement.acceptsPermissionResult(oldCode))
    }
}
