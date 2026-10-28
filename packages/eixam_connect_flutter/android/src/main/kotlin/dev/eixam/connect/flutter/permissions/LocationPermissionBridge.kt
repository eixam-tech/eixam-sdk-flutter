package dev.eixam.connect.flutter.permissions

import android.Manifest
import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.location.LocationManagerCompat
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

internal class LocationPermissionBridge(
    messenger: BinaryMessenger,
    private val context: Context,
) : MethodChannel.MethodCallHandler,
    PluginRegistry.RequestPermissionsResultListener,
    PluginRegistry.ActivityResultListener, Application.ActivityLifecycleCallbacks {
    private val channel = MethodChannel(messenger, "dev.eixam.connect_flutter/location_permissions")
    private val attempts = context.getSharedPreferences("eixam_location_requests", Context.MODE_PRIVATE)
    private var binding: ActivityPluginBinding? = null
    private var pending: MethodChannel.Result? = null
    private val request = LocationPermissionRequest()
    private val application = context.applicationContext as Application

    init {
        channel.setMethodCallHandler(this)
        application.registerActivityLifecycleCallbacks(this)
    }

    fun attach(binding: ActivityPluginBinding) {
        this.binding = binding
        binding.addRequestPermissionsResultListener(this)
        binding.addActivityResultListener(this)
    }

    fun detach(forConfigurationChange: Boolean = false) {
        binding?.removeRequestPermissionsResultListener(this)
        binding?.removeActivityResultListener(this)
        binding = null
        if (!forConfigurationChange) {
            pending?.error("activity_detached", "Location request interrupted by Activity detach.", null)
            pending = null
            request.clear()
        }
    }

    fun dispose() {
        detach()
        channel.setMethodCallHandler(null)
        application.unregisterActivityLifecycleCallbacks(this)
    }

    private fun granted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    private fun canRequest(permission: String, key: String): Boolean {
        val activity = binding?.activity ?: return false
        return !attempts.getBoolean(key, false) ||
            ActivityCompat.shouldShowRequestPermissionRationale(activity, permission)
    }

    private fun state(): Map<String, Any?> {
        val fine = granted(Manifest.permission.ACCESS_FINE_LOCATION)
        val foreground = fine || granted(Manifest.permission.ACCESS_COARSE_LOCATION)
        val background = LocationPermissionPolicy.backgroundGranted(
            Build.VERSION.SDK_INT, foreground,
            Build.VERSION.SDK_INT < 29 || granted(Manifest.permission.ACCESS_BACKGROUND_LOCATION),
        )
        val manager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        return mapOf(
            "apiLevel" to Build.VERSION.SDK_INT,
            "foregroundGranted" to foreground,
            "backgroundGranted" to background,
            "preciseGranted" to fine,
            "locationServicesEnabled" to LocationManagerCompat.isLocationEnabled(manager),
            "foregroundRequested" to attempts.getBoolean("foreground", false),
            "foregroundRequestAvailable" to (!foreground && canRequest(
                Manifest.permission.ACCESS_COARSE_LOCATION, "foreground",
            )),
            "backgroundRequestAvailable" to (foreground && !background && Build.VERSION.SDK_INT >= 29 &&
                canRequest(Manifest.permission.ACCESS_BACKGROUND_LOCATION, "background")),
            "backgroundPermissionOptionLabel" to if (Build.VERSION.SDK_INT >= 30)
                context.packageManager.backgroundPermissionOptionLabel.toString() else null,
        )
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "getState") {
            result.success(state())
            return
        }
        if (call.method != "requestForeground" && call.method != "requestBackground") {
            result.notImplemented()
            return
        }
        val activity = binding?.activity
        if (activity == null) {
            result.error("activity_unavailable", "A visible Activity is required.", null)
            return
        }
        if (pending != null) {
            result.error("permission_request_in_progress", "A location request is already active.", null)
            return
        }
        val state = state()
        val action = LocationPermissionPolicy.action(
            call.method == "requestBackground",
            state["foregroundGranted"] == true,
            state["backgroundGranted"] == true,
            state["foregroundRequestAvailable"] == true,
            state["backgroundRequestAvailable"] == true,
        )
        if (action == LocationPermissionPolicy.Action.NONE) {
            result.success(state)
            return
        }
        pending = result
        val requestCode = request.begin(action == LocationPermissionPolicy.Action.SETTINGS)
        try {
            when (action) {
                LocationPermissionPolicy.Action.FOREGROUND -> {
                    attempts.edit().putBoolean("foreground", true).apply()
                    ActivityCompat.requestPermissions(activity, arrayOf(
                        Manifest.permission.ACCESS_COARSE_LOCATION,
                        Manifest.permission.ACCESS_FINE_LOCATION,
                    ), requestCode)
                }
                LocationPermissionPolicy.Action.BACKGROUND -> {
                    attempts.edit().putBoolean("background", true).apply()
                    ActivityCompat.requestPermissions(activity, arrayOf(
                        Manifest.permission.ACCESS_BACKGROUND_LOCATION,
                    ), requestCode)
                }
                LocationPermissionPolicy.Action.SETTINGS -> openSettings(activity, requestCode)
                LocationPermissionPolicy.Action.NONE -> Unit
            }
        } catch (error: Exception) {
            pending = null
            request.clear()
            result.error("location_permission_ui_unavailable", error.message, null)
        }
    }

    private fun openSettings(activity: Activity, requestCode: Int) {
        // No documented public intent targets an app's Location permission page.
        // The separate runtime request is preferred; app details is the fallback.
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", context.packageName, null))
        if (intent.resolveActivity(context.packageManager) == null) {
            throw IllegalStateException("App details Settings cannot be resolved.")
        }
        activity.startActivityForResult(intent, requestCode)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray,
    ): Boolean {
        if (pending == null || !request.acceptsPermissionResult(requestCode)) return false
        complete()
        return true
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (pending == null || !request.acceptsActivityResult(requestCode)) return false
        complete()
        return true
    }

    private fun complete() {
        val result = pending
        pending = null
        request.clear()
        // Query OS truth; the result code and requested permission are not grants.
        result?.success(state())
    }

    override fun onActivityPaused(activity: Activity) {
        if (activity === binding?.activity) request.onHostPaused()
    }

    override fun onActivityResumed(activity: Activity) {
        // Returning through Home/Recents need not finish the Settings Activity.
        if (activity === binding?.activity && request.shouldCompleteOnResume()) complete()
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
    override fun onActivityStarted(activity: Activity) = Unit
    override fun onActivityStopped(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
    override fun onActivityDestroyed(activity: Activity) = Unit

}
