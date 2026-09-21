package dev.eixam.connect.flutter.protection

internal class ProtectionPlatformEventBuffer(
    private val capacity: Int,
) {
    private val events = ArrayDeque<Map<String, Any?>>()

    fun add(event: Map<String, Any?>) {
        if (events.size >= capacity) {
            events.removeFirst()
        }
        events.addLast(event)
    }

    fun drain(consumer: (Map<String, Any?>) -> Unit) {
        while (events.isNotEmpty()) {
            consumer(events.removeFirst())
        }
    }
}
