package app.tandem.receiver

import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Build
import android.util.DisplayMetrics
import android.view.Display
import android.view.Surface
import android.view.WindowManager
import app.tandem.receiver.net.Orientation
import app.tandem.receiver.net.SafeInsets
import app.tandem.receiver.net.ScreenInfo

/**
 * The physical geometry the host needs to build a matching virtual display
 * (PROTOCOL.md §3.2 and §5.2).
 *
 * The receiver runs its display view edge to edge behind the system bars, so
 * the *usable* area is the whole panel; only a display cutout actually removes
 * pixels, and that is what `safeInsets` reports.
 */
object DeviceMetrics {
    fun screenInfo(context: Context): ScreenInfo {
        val windowManager = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val display = displayOf(context, windowManager)

        val (widthPx, heightPx) =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && runCatching { windowManager.maximumWindowMetrics }.isSuccess) {
                val bounds = windowManager.maximumWindowMetrics.bounds
                bounds.width() to bounds.height()
            } else {
                @Suppress("DEPRECATION")
                val metrics = DisplayMetrics().also { display?.getRealMetrics(it) }
                metrics.widthPixels to metrics.heightPixels
            }

        return ScreenInfo(
            wPx = widthPx,
            hPx = heightPx,
            scale = context.resources.displayMetrics.density,
            refreshHz = (display?.refreshRate ?: 60f).toInt().coerceIn(24, 240),
            safeInsets = safeInsets(display),
        )
    }

    private fun safeInsets(display: Display?): SafeInsets {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return SafeInsets.ZERO
        val cutout = display?.cutout ?: return SafeInsets.ZERO
        return SafeInsets(
            top = cutout.safeInsetTop,
            bottom = cutout.safeInsetBottom,
            left = cutout.safeInsetLeft,
            right = cutout.safeInsetRight,
        )
    }

    /**
     * Orientation as PROTOCOL.md §3.2 names it.
     *
     * Decided from the bounds rather than the rotation alone, because a tablet
     * whose natural orientation is landscape reports rotation 0 while showing a
     * landscape picture; the rotation then only chooses which way round it is.
     */
    fun orientation(context: Context): Orientation {
        val windowManager = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val display = displayOf(context, windowManager)
        val rotation = display?.rotation ?: Surface.ROTATION_0
        val screen = screenInfo(context)
        val landscape = screen.wPx > screen.hPx
        return when {
            landscape && rotation == Surface.ROTATION_270 -> Orientation.LANDSCAPE_RIGHT
            landscape -> Orientation.LANDSCAPE_LEFT
            rotation == Surface.ROTATION_180 -> Orientation.PORTRAIT_UPSIDE_DOWN
            else -> Orientation.PORTRAIT
        }
    }

    /**
     * Resolve the default display without requiring a visual Context. The
     * receiver builds HELLO_ACK from a socket thread using the application
     * context, and `Context.display` throws there ("Tried to obtain display
     * from a Context not associated with one").
     */
    private fun displayOf(context: Context, windowManager: WindowManager): Display? {
        val dm = context.getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager
        dm?.getDisplay(Display.DEFAULT_DISPLAY)?.let { return it }
        @Suppress("DEPRECATION")
        return windowManager.defaultDisplay
    }

    fun model(): String = "${Build.MANUFACTURER} ${Build.MODEL}".trim()
}
