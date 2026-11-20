package dev.eixam.connect.flutter.protection

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** F17c ambiguous TAG SOS prompt: the notification action contract. */
class ProtectionSosPromptSpecTest {
    @Test
    fun `send SOS is one tap without unlock and no is behind the unlock`() {
        val (send, stop) = ProtectionSosPromptSpec.actions
        assertEquals("sendSos", send.choice)
        assertFalse("Send SOS never needs an unlock", send.requiresUnlock)
        assertFalse("Send SOS is a broadcast, no app launch", send.opensActivity)
        assertEquals("stopTag", stop.choice)
        assertTrue("No needs the unlock", stop.requiresUnlock)
        assertTrue("No is an activity: the lock screen asks for the unlock first", stop.opensActivity)
    }

    @Test
    fun `authentication required is used where the platform has it`() {
        assertFalse(ProtectionSosPromptSpec.authenticationRequiredSupported(30))
        assertTrue(ProtectionSosPromptSpec.authenticationRequiredSupported(31))
    }

    @Test
    fun `owner decision - no full-screen intent`() {
        assertFalse(ProtectionSosPromptSpec.usesFullScreenIntent)
    }

    @Test
    fun `intent actions map to choices`() {
        assertEquals("sendSos", ProtectionSosPromptSpec.choiceFor(ProtectionSosPromptSpec.actionSendSos))
        assertEquals("stopTag", ProtectionSosPromptSpec.choiceFor(ProtectionSosPromptSpec.actionStopTag))
        assertNull(ProtectionSosPromptSpec.choiceFor("other"))
        assertNull(ProtectionSosPromptSpec.choiceFor(null))
    }

    @Test
    fun `remaining seconds count down from 30 to 0`() {
        val deadline = 1_000_000L
        assertEquals(30L, ProtectionSosPromptSpec.remainingSeconds(deadline, deadline - 30_000L))
        assertEquals(1L, ProtectionSosPromptSpec.remainingSeconds(deadline, deadline - 1L))
        assertEquals(0L, ProtectionSosPromptSpec.remainingSeconds(deadline, deadline))
        assertEquals(0L, ProtectionSosPromptSpec.remainingSeconds(deadline, deadline + 5_000L))
    }

    @Test
    fun `prompt events are live only, never replayed later`() {
        assertTrue("ownTagSosPromptOpened" in ProtectionPlatformEventBuffer.liveOnlyTypes)
        assertTrue("ownTagSosPromptClosed" in ProtectionPlatformEventBuffer.liveOnlyTypes)
    }
}
