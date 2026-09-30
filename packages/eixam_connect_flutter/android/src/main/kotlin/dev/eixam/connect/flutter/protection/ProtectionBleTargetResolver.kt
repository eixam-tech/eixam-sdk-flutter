package dev.eixam.connect.flutter.protection

internal fun resolveProtectionBleTarget(
    activeDeviceId: String?,
    bleHardwareId: String?,
): String? =
    bleHardwareId?.trim()?.takeIf { it.isNotEmpty() }
        ?: activeDeviceId?.trim()?.takeIf { it.isNotEmpty() }
