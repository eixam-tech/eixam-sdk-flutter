package dev.eixam.connect.flutter.protection

internal class ProtectionPlatformEventBuffer(
    private val capacity: Int,
) {
    private val events = ArrayDeque<Map<String, Any?>>()

    fun add(event: Map<String, Any?>) {
        if (event["type"] in liveOnlyTypes) {
            // F17c M-A: valid only for the guard state at the moment native
            // decided; replayed later it could stop a genuine new SOS. A
            // missing listener means no Dart link owner to write it anyway.
            return
        }
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

    companion object {
        /** Events delivered to a live listener only, never replayed. */
        val liveOnlyTypes: Set<String> = setOf("ownTagSosStopRequired")
    }
}
