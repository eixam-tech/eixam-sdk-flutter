package dev.eixam.connect.flutter.dfu

import android.app.Activity
import no.nordicsemi.android.dfu.DfuBaseService

class EixamDfuService : DfuBaseService() {
    override fun getNotificationTarget(): Class<out Activity>? {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val className = launchIntent?.component?.className ?: return null
        return runCatching {
            Class.forName(className).asSubclass(Activity::class.java)
        }.getOrNull()
    }

    override fun isDebug(): Boolean = false
}
