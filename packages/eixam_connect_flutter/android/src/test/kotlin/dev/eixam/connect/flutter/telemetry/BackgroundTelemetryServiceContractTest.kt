package dev.eixam.connect.flutter.telemetry

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BackgroundTelemetryServiceContractTest {
    private val serviceSource = File(
        "src/main/kotlin/dev/eixam/connect/flutter/telemetry/EixamTelemetryForegroundService.kt",
    ).readText()

    @Test
    fun `normal telemetry uses one shot location request instead of service listener`() {
        assertTrue(serviceSource.contains("requestSingleLocation("))
        assertTrue(
            serviceSource.contains(
                "manager.requestLocationUpdates(provider, 0L, 0f, listener, Looper.getMainLooper())",
            ),
        )
        assertFalse(serviceSource.contains("manager.requestLocationUpdates(provider, 10000L, 3f, this)"))
        assertFalse(serviceSource.contains("startLocationUpdates()"))
    }

    @Test
    fun `SOS movement listener is scoped to SOS interval and removed on close`() {
        assertTrue(
            serviceSource.contains(
                "manager.requestLocationUpdates(provider, sosIntervalMs, sosMovementThresholdMeters, this)",
            ),
        )
        assertTrue(serviceSource.contains("if (store.isSosOpen())"))
        assertTrue(serviceSource.contains("stopSosLocationUpdates()"))
    }
}
