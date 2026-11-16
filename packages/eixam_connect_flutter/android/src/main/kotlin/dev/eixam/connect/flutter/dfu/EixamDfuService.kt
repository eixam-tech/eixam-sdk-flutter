package dev.eixam.connect.flutter.dfu

import android.app.Activity
import android.content.Intent
import no.nordicsemi.android.dfu.DfuBaseService

class EixamDfuService : DfuBaseService() {
    override fun getNotificationTarget(): Class<out Activity>? {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val className = launchIntent?.component?.className ?: return null
        return runCatching {
            Class.forName(className).asSubclass(Activity::class.java)
        }.getOrNull()
    }

    /**
     * The Nordic default stops the service when the user swipes the app away.
     * Its onDestroy() flags an abort, which makes the legacy implementation
     * send Reset (Op Code 6) mid-transfer and strands the TAG in USB/UF2-only
     * mode. Keep the foreground transfer alive instead; the Dart session is
     * reconciled on the next launch. (Behaviour not hardware-verified.)
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        // Intentionally no super call and no stopSelf().
    }

    override fun isDebug(): Boolean = false
}
