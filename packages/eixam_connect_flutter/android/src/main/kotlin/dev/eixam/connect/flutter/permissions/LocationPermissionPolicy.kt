package dev.eixam.connect.flutter.permissions

internal object LocationPermissionPolicy {
    enum class Action { NONE, FOREGROUND, BACKGROUND, SETTINGS }

    fun backgroundGranted(api: Int, foreground: Boolean, background: Boolean): Boolean =
        foreground && (api < 29 || background)

    fun action(
        backgroundRequest: Boolean,
        foreground: Boolean,
        background: Boolean,
        canRequestForeground: Boolean,
        canRequestBackground: Boolean,
    ): Action = when {
        backgroundRequest && !foreground -> Action.NONE // Incremental, separate user actions.
        backgroundRequest && background -> Action.NONE
        !backgroundRequest && foreground -> Action.NONE
        backgroundRequest && canRequestBackground -> Action.BACKGROUND
        !backgroundRequest && canRequestForeground -> Action.FOREGROUND
        else -> Action.SETTINGS
    }
}
