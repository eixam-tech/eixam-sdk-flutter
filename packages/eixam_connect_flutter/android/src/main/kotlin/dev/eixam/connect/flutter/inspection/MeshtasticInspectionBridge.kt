package dev.eixam.connect.flutter.inspection

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Cancels an unfinished inspection bond; never removes an established bond. */
class MeshtasticInspectionBridge(messenger: BinaryMessenger, private val context: Context) {
    private val channel = MethodChannel(messenger, "dev.eixam.connect.flutter/meshtastic_inspection")

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "cancelPendingBond") {
                result.notImplemented()
            } else {
                try {
                    val id = requireNotNull(call.argument<String>("deviceId"))
                    result.success(cancelPendingBond(id))
                } catch (error: Exception) {
                    result.error("inspectionBondCleanupFailed", error.javaClass.simpleName, null)
                }
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun cancelPendingBond(id: String): Boolean {
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val device = manager.adapter.getRemoteDevice(id)
        return cancelUnfinishedBond(
            state = { device.bondState },
            cancel = { device.javaClass.getMethod("cancelBondProcess").invoke(device) as Boolean },
        )
    }

    fun dispose() { channel.setMethodCallHandler(null) }
}

internal fun cancelUnfinishedBond(state: () -> Int, cancel: () -> Boolean): Boolean {
    if (state() != BluetoothDevice.BOND_BONDING) return false
    // FlutterBluePlus exposes removeBond, which would erase established
    // credentials. Use Android's pending-only cancellation instead.
    val cancelled = cancel()
    check(cancelled || state() != BluetoothDevice.BOND_BONDING)
    return state() == BluetoothDevice.BOND_BONDING
}

