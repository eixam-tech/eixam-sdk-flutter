package dev.eixam.connect.flutter.permissions

/** Identifies one native UI transaction, including Settings returns via resume. */
internal class LocationPermissionRequest {
    private var code: Int? = null
    private var settings = false
    private var hostPaused = false

    fun begin(settings: Boolean): Int {
        check(code == null) { "A location request is already active." }
        this.settings = settings
        hostPaused = false
        val next = nextCode
        nextCode = if (nextCode == 60000) 48120 else nextCode + 1
        code = next
        return next
    }

    fun acceptsPermissionResult(code: Int): Boolean = this.code == code && !settings
    fun acceptsActivityResult(code: Int): Boolean = this.code == code && settings

    fun onHostPaused() {
        if (settings && code != null) hostPaused = true
    }

    fun shouldCompleteOnResume(): Boolean = code != null && settings && hostPaused

    fun clear() {
        code = null
        settings = false
        hostPaused = false
    }

    companion object {
        // Shared across plugin instances so a delayed result cannot complete a
        // newer transaction following engine detach/reattach in the same process.
        private var nextCode = 48120
    }
}
