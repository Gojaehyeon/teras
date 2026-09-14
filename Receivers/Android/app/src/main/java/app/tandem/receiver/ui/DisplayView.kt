package app.tandem.receiver.ui

import android.content.Context
import android.graphics.Color
import android.os.SystemClock
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.ViewGroup
import android.widget.FrameLayout
import app.tandem.receiver.input.InputRouter
import app.tandem.receiver.input.InputSink
import app.tandem.receiver.input.VideoViewport

/**
 * The streaming view: a [SurfaceView] letterboxed to the encoded frame's aspect
 * ratio inside a black field, with all input routed through [InputRouter].
 *
 * Input is taken on the container rather than the surface so a drag that runs
 * onto a letterbox bar still reaches the edge of the remote desktop.
 */
class DisplayView(context: Context) : FrameLayout(context) {
    private val surfaceView = SurfaceView(context)

    private var videoWidth = 0
    private var videoHeight = 0

    /** Fired when the decoder's target surface appears or is destroyed. */
    var onSurfaceChanged: ((Surface?) -> Unit)? = null

    /** Fired on a triple tap, which toggles the stats overlay. */
    var onTripleTap: (() -> Unit)? = null

    private var tapCount = 0
    private var lastTapUptime = 0L
    private var lastTapX = 0f
    private var lastTapY = 0f

    private val router =
        InputRouter(
            sink =
                object : InputSink {
                    override fun touch(phase: Byte, pointers: List<app.tandem.receiver.net.TouchPointer>) =
                        sink?.touch(phase, pointers) ?: Unit

                    override fun scroll(x: Float, y: Float, dx: Float, dy: Float, phase: Byte) =
                        sink?.scroll(x, y, dx, dy, phase) ?: Unit

                    override fun pointer(kind: Byte, button: Byte, x: Float, y: Float) =
                        sink?.pointer(kind, button, x, y) ?: Unit

                    override fun key(event: app.tandem.receiver.net.KeyEvent) =
                        sink?.key(event) ?: Unit
                },
            viewportProvider = ::viewport,
            densityProvider = { resources.displayMetrics.density },
        )

    /** The live session's input path; null while no session is up. */
    var sink: InputSink? = null

    init {
        setBackgroundColor(Color.BLACK)
        isFocusable = true
        isFocusableInTouchMode = true
        addView(
            surfaceView,
            LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT),
        )
        surfaceView.holder.addCallback(
            object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) {
                    onSurfaceChanged?.invoke(holder.surface)
                }

                override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                    onSurfaceChanged?.invoke(holder.surface)
                }

                override fun surfaceDestroyed(holder: SurfaceHolder) {
                    onSurfaceChanged?.invoke(null)
                }
            },
        )
    }

    /** Sets the encoded frame size so the surface can be letterboxed to it. */
    fun setVideoSize(width: Int, height: Int) {
        if (width == videoWidth && height == videoHeight) return
        videoWidth = width
        videoHeight = height
        requestLayout()
    }

    /** Drops any gesture in flight, e.g. when the session ends. */
    fun resetInput() = router.reset()

    fun dispatchHardwareKey(event: android.view.KeyEvent): Boolean = router.onKeyEvent(event)

    private fun viewport(): VideoViewport =
        VideoViewport(
            viewWidth = width,
            viewHeight = height,
            videoWidth = if (videoWidth > 0) videoWidth else width,
            videoHeight = if (videoHeight > 0) videoHeight else height,
        )

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val height = MeasureSpec.getSize(heightMeasureSpec)
        setMeasuredDimension(width, height)

        // The surface is measured at the letterboxed size, not the view size:
        // a SurfaceView takes its buffer dimensions from its layout, so letting
        // it fill the view would stretch the picture.
        val box =
            VideoViewport(
                viewWidth = width,
                viewHeight = height,
                videoWidth = if (videoWidth > 0) videoWidth else width,
                videoHeight = if (videoHeight > 0) videoHeight else height,
            )
        surfaceView.measure(
            MeasureSpec.makeMeasureSpec(box.width.toInt().coerceAtLeast(1), MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(box.height.toInt().coerceAtLeast(1), MeasureSpec.EXACTLY),
        )
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        val box = viewport()
        val x = box.left.toInt()
        val y = box.top.toInt()
        surfaceView.layout(x, y, x + surfaceView.measuredWidth, y + surfaceView.measuredHeight)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        detectTripleTap(event)
        return router.onTouchEvent(event) || super.onTouchEvent(event)
    }

    override fun onGenericMotionEvent(event: MotionEvent): Boolean =
        router.onGenericMotionEvent(event) || super.onGenericMotionEvent(event)

    private fun detectTripleTap(event: MotionEvent) {
        if (event.actionMasked != MotionEvent.ACTION_UP) return
        val now = SystemClock.uptimeMillis()
        val quick = now - lastTapUptime <= TRIPLE_TAP_WINDOW_MS
        val near =
            kotlin.math.abs(event.x - lastTapX) < TRIPLE_TAP_SLOP_PX &&
                kotlin.math.abs(event.y - lastTapY) < TRIPLE_TAP_SLOP_PX
        tapCount = if (quick && near) tapCount + 1 else 1
        lastTapUptime = now
        lastTapX = event.x
        lastTapY = event.y
        if (tapCount >= 3) {
            tapCount = 0
            onTripleTap?.invoke()
        }
    }

    private companion object {
        const val TRIPLE_TAP_WINDOW_MS = 350L
        const val TRIPLE_TAP_SLOP_PX = 60f
    }
}
