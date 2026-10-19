package dev.eixam.connect.flutter.storage

import io.flutter.plugin.common.BinaryMessenger
import java.io.File
import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Test

class ActivityRecordingStorageBridgeTest {
    @Test fun detachingAnOlderEngineDoesNotUnregisterTheNewEngine() {
        val a = TestMessenger()
        val b = TestMessenger()
        val old = ActivityRecordingStorageBridge(a) { File("unused") }
        val current = ActivityRecordingStorageBridge(b) { File("unused") }
        assertEquals(1, a.handlers.size)
        assertEquals(1, b.handlers.size)
        old.unregister()
        assertEquals(0, a.handlers.size)
        assertEquals(1, b.handlers.size)
        current.unregister()
        assertEquals(0, b.handlers.size)
    }

    private class TestMessenger : BinaryMessenger {
        val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler>()
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            if (handler == null) handlers.remove(channel) else handlers[channel] = handler
        }
    }
}
