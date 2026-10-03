package dev.eixam.connect.flutter.telemetry

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.CellInfo
import android.telephony.CellInfoCdma
import android.telephony.CellInfoGsm
import android.telephony.CellInfoLte
import android.telephony.CellInfoNr
import android.telephony.CellInfoTdscdma
import android.telephony.CellInfoWcdma
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyDisplayInfo
import android.telephony.TelephonyManager
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import org.json.JSONObject

internal data class PhoneRadioRaw(
    val networkType: Int?,
    val overrideNetworkType: Int?,
    val cellularDataConnected: Boolean,
) {
    fun toJson(): JSONObject {
        val json = JSONObject()
        networkType?.let { json.put("networkType", it) }
        overrideNetworkType?.let { json.put("overrideNetworkType", it) }
        json.put("cellularDataConnected", cellularDataConnected)
        return json
    }

    fun toMap(): Map<String, Any?> {
        val map = LinkedHashMap<String, Any?>()
        networkType?.let { map["networkType"] = it }
        overrideNetworkType?.let { map["overrideNetworkType"] = it }
        map["cellularDataConnected"] = cellularDataConnected
        return map
    }
}

internal data class CellRadioHint(
    val networkType: Int?,
    val overrideNetworkType: Int?,
)

internal object PhoneRadioReader {
    fun read(context: Context): PhoneRadioRaw {
        return try {
            readUnchecked(context)
        } catch (_: Throwable) {
            // A radio failure must not drop the location sample.
            PhoneRadioRaw(null, null, false)
        }
    }

    private fun readUnchecked(context: Context): PhoneRadioRaw {
        val app = context.applicationContext
        val display = PhoneRadioMonitor.snapshot()
        val connected = try {
            cellularDataConnected(app)
        } catch (_: RuntimeException) {
            false
        }
        val displayNetwork = usableDisplayNetwork(display.networkType)
        if (displayNetwork != null || display.overrideNetworkType != null) {
            return PhoneRadioRaw(
                networkType = displayNetwork,
                overrideNetworkType = display.overrideNetworkType,
                cellularDataConnected = connected,
            )
        }
        val cells = cellRadioHint(app)
        return PhoneRadioRaw(
            networkType = cells.networkType,
            overrideNetworkType = cells.overrideNetworkType,
            cellularDataConnected = connected,
        )
    }

    private fun usableDisplayNetwork(networkType: Int?): Int? {
        if (networkType == null ||
            networkType == TelephonyManager.NETWORK_TYPE_UNKNOWN ||
            networkType == 18 // NETWORK_TYPE_IWLAN, API 25+
        ) {
            return null
        }
        return networkType
    }

    private fun cellRadioHint(context: Context): CellRadioHint {
        return try {
            hintFromCellInfo(context)
        } catch (_: RuntimeException) {
            CellRadioHint(null, null)
        }
    }

    private fun hintFromCellInfo(context: Context): CellRadioHint {
        val fine = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        val coarse = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        if (!fine && !coarse) {
            return CellRadioHint(null, null)
        }
        val telephony = telephonyManager(context) ?: return CellRadioHint(null, null)
        val cells = try {
            telephony.allCellInfo
        } catch (_: RuntimeException) {
            null
        } ?: return CellRadioHint(null, null)
        return hintFromCells(cells)
    }

    internal fun hintFromCells(cells: List<CellInfo>): CellRadioHint {
        val registered = cells.filter { it.isRegistered }
        if (registered.isEmpty()) {
            return CellRadioHint(null, null)
        }
        val hasNr = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && hasRegisteredNr(registered)
        val hasLte = registered.any { it is CellInfoLte }
        // NR registered beside LTE is NSA. Standalone NR has no LTE anchor.
        if (hasNr && hasLte) {
            return CellRadioHint(
                networkType = TelephonyManager.NETWORK_TYPE_LTE,
                // TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NR_NSA. Literal so
                // API 21–29 never loads that class.
                overrideNetworkType = 3,
            )
        }
        if (hasNr) {
            return CellRadioHint(TelephonyManager.NETWORK_TYPE_NR, null)
        }
        if (hasLte) {
            return CellRadioHint(TelephonyManager.NETWORK_TYPE_LTE, null)
        }
        if (registered.any { it is CellInfoWcdma }) {
            return CellRadioHint(TelephonyManager.NETWORK_TYPE_UMTS, null)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            hasRegisteredTdscdma(registered)
        ) {
            return CellRadioHint(TelephonyManager.NETWORK_TYPE_TD_SCDMA, null)
        }
        if (registered.any { it is CellInfoGsm }) {
            return CellRadioHint(TelephonyManager.NETWORK_TYPE_GSM, null)
        }
        if (registered.any { it is CellInfoCdma }) {
            return CellRadioHint(TelephonyManager.NETWORK_TYPE_CDMA, null)
        }
        return CellRadioHint(null, null)
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun hasRegisteredNr(cells: List<CellInfo>): Boolean {
        return cells.any { it is CellInfoNr }
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun hasRegisteredTdscdma(cells: List<CellInfo>): Boolean {
        return cells.any { it is CellInfoTdscdma }
    }

    private fun cellularDataConnected(context: Context): Boolean {
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val network = manager.activeNetwork ?: return false
            val capabilities = manager.getNetworkCapabilities(network) ?: return false
            return capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
        }
        @Suppress("DEPRECATION")
        val info = manager.activeNetworkInfo ?: return false
        @Suppress("DEPRECATION")
        return info.isConnected && info.type == ConnectivityManager.TYPE_MOBILE
    }
}

internal object PhoneRadioMonitor {
    private val lock = Any()
    private var refs = 0
    private var telephonyManager: TelephonyManager? = null
    private var callback: TelephonyCallback? = null

    @Suppress("DEPRECATION")
    private var legacyListener: PhoneStateListener? = null
    private var networkType: Int? = null
    private var overrideNetworkType: Int? = null

    fun acquire(context: Context) {
        val app = context.applicationContext
        if (Looper.myLooper() != Looper.getMainLooper()) {
            Handler(Looper.getMainLooper()).post { acquire(app) }
            return
        }
        val shouldStart = synchronized(lock) {
            refs += 1
            refs == 1
        }
        if (shouldStart) {
            start(app)
        }
    }

    fun release() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            Handler(Looper.getMainLooper()).post { release() }
            return
        }
        val shouldStop = synchronized(lock) {
            if (refs <= 0) {
                false
            } else {
                refs -= 1
                refs == 0
            }
        }
        if (shouldStop) {
            stopListening()
        }
    }

    fun snapshot(): PhoneRadioDisplay {
        return synchronized(lock) {
            PhoneRadioDisplay(networkType, overrideNetworkType)
        }
    }

    private fun start(context: Context) {
        val telephony = telephonyManager(context) ?: return
        telephonyManager = telephony
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val displayCallback = DisplayCallback()
                telephony.registerTelephonyCallback(context.mainExecutor, displayCallback)
                callback = displayCallback
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val listener = LegacyDisplayListener()
                @Suppress("DEPRECATION")
                telephony.listen(listener, PhoneStateListener.LISTEN_DISPLAY_INFO_CHANGED)
                legacyListener = listener
            }
        } catch (_: RuntimeException) {
            // Location-backed cell info still supplies a generation.
        }
    }

    private fun stopListening() {
        val telephony = telephonyManager
        val currentCallback = callback
        val currentListener = legacyListener
        callback = null
        legacyListener = null
        telephonyManager = null
        synchronized(lock) {
            networkType = null
            overrideNetworkType = null
        }
        if (telephony == null) {
            return
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && currentCallback != null) {
                telephony.unregisterTelephonyCallback(currentCallback)
            } else if (currentListener != null) {
                @Suppress("DEPRECATION")
                telephony.listen(currentListener, PhoneStateListener.LISTEN_NONE)
            }
        } catch (_: RuntimeException) {
            // Listener is already gone.
        }
    }

    internal fun note(reportedNetworkType: Int, reportedOverride: Int) {
        synchronized(lock) {
            networkType = reportedNetworkType.takeIf {
                it != TelephonyManager.NETWORK_TYPE_UNKNOWN
            }
            overrideNetworkType = reportedOverride.takeIf {
                it != TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NONE
            }
        }
    }

    @RequiresApi(Build.VERSION_CODES.S)
    private class DisplayCallback :
        TelephonyCallback(),
        TelephonyCallback.DisplayInfoListener {
        override fun onDisplayInfoChanged(displayInfo: TelephonyDisplayInfo) {
            PhoneRadioMonitor.note(displayInfo.networkType, displayInfo.overrideNetworkType)
        }
    }

    @Suppress("DEPRECATION")
    @RequiresApi(Build.VERSION_CODES.R)
    private class LegacyDisplayListener : PhoneStateListener() {
        override fun onDisplayInfoChanged(telephonyDisplayInfo: TelephonyDisplayInfo) {
            PhoneRadioMonitor.note(
                telephonyDisplayInfo.networkType,
                telephonyDisplayInfo.overrideNetworkType,
            )
        }
    }
}

internal data class PhoneRadioDisplay(
    val networkType: Int?,
    val overrideNetworkType: Int?,
)

private fun telephonyManager(context: Context): TelephonyManager? {
    return context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
}
