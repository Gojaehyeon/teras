package app.tandem.receiver.input

import android.os.Handler
import android.os.Looper
import android.view.InputDevice
import android.view.MotionEvent
import android.view.ViewConfiguration
import app.tandem.receiver.net.KeyEvent
import app.tandem.receiver.net.PointerButton
import app.tandem.receiver.net.PointerKind
import app.tandem.receiver.net.ScrollPhase
import app.tandem.receiver.net.TouchPhase
import app.tandem.receiver.net.TouchPointer
import app.tandem.receiver.net.TouchTool
import android.view.KeyEvent as AndroidKeyEvent

/**
 * Turns Android input into Tandem input frames (PROTOCOL.md §6).
 *
 * The gesture policy lives here rather than on the host, as §6.1 requires:
 *
 *  * one finger or stylus is a left drag, sent as TOUCH;
 *  * two fingers dragging becomes SCROLL, and the touch that started it is
 *    cancelled so the host does not leave a button down;
 *  * a long press without movement becomes a right click, sent as POINTER;
 *  * a mouse or trackpad is POINTER throughout, including its wheel.
 */
class InputRouter(
    private val sink: InputSink,
    private val viewportProvider: () -> VideoViewport,
    private val densityProvider: () -> Float,
    private val handler: Handler = Handler(Looper.getMainLooper()),
    private val longPressTimeoutMs: Long = ViewConfiguration.getLongPressTimeout().toLong(),
    private val touchSlopPx: Float = DEFAULT_TOUCH_SLOP_PX,
) {
    private enum class Mode { IDLE, TOUCH, SCROLL, RIGHT_CLICK, DRAINING }

    private var mode = Mode.IDLE
    private var downX = 0f
    private var downY = 0f
    private var lastCentroidX = 0f
    private var lastCentroidY = 0f
    private var wheelActive = false

    private val longPressRunnable = Runnable { promoteToRightClick() }
    private val wheelEndRunnable =
        Runnable {
            if (wheelActive) {
                wheelActive = false
                sink.scroll(lastCentroidX, lastCentroidY, 0f, 0f, ScrollPhase.ENDED)
            }
        }

    /** Drops any gesture in flight, e.g. when the session ends mid-drag. */
    fun reset() {
        handler.removeCallbacks(longPressRunnable)
        handler.removeCallbacks(wheelEndRunnable)
        if (mode == Mode.TOUCH) sink.touch(TouchPhase.CANCELLED, emptyList())
        if (mode == Mode.SCROLL) sink.scroll(lastCentroidX, lastCentroidY, 0f, 0f, ScrollPhase.ENDED)
        if (mode == Mode.RIGHT_CLICK) {
            sink.pointer(PointerKind.UP, PointerButton.RIGHT, lastCentroidX, lastCentroidY)
        }
        mode = Mode.IDLE
        wheelActive = false
    }

    // ------------------------------------------------------------- touch screen

    /** Handles [MotionEvent]s delivered to the display view. */
    fun onTouchEvent(event: MotionEvent): Boolean {
        if (isMouse(event)) return onMouseTouch(event)

        return when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> onPrimaryDown(event)
            MotionEvent.ACTION_POINTER_DOWN -> onSecondaryDown(event)
            MotionEvent.ACTION_MOVE -> onMove(event)
            MotionEvent.ACTION_POINTER_UP -> onSecondaryUp(event)
            MotionEvent.ACTION_UP -> onPrimaryUp(event)
            MotionEvent.ACTION_CANCEL -> onCancel()
            else -> false
        }
    }

    private fun onPrimaryDown(event: MotionEvent): Boolean {
        mode = Mode.TOUCH
        downX = event.x
        downY = event.y
        lastCentroidX = normalizedX(event.x)
        lastCentroidY = normalizedY(event.y)
        sink.touch(TouchPhase.BEGAN, pointersOf(event))
        handler.postDelayed(longPressRunnable, longPressTimeoutMs)
        return true
    }

    private fun onSecondaryDown(event: MotionEvent): Boolean {
        handler.removeCallbacks(longPressRunnable)
        if (event.pointerCount == 2 && mode == Mode.TOUCH) {
            // Hand the gesture over to scrolling and release the button the
            // first finger pressed, so the host does not drag while we scroll.
            sink.touch(TouchPhase.CANCELLED, pointersOf(event))
            mode = Mode.SCROLL
            lastCentroidX = centroidX(event)
            lastCentroidY = centroidY(event)
            sink.scroll(
                normalizedX(lastCentroidX),
                normalizedY(lastCentroidY),
                0f,
                0f,
                ScrollPhase.BEGIN,
            )
            return true
        }
        if (mode == Mode.TOUCH) {
            sink.touch(TouchPhase.BEGAN, pointersOf(event))
            return true
        }
        return true
    }

    private fun onMove(event: MotionEvent): Boolean {
        when (mode) {
            Mode.TOUCH -> {
                if (movedBeyondSlop(event)) handler.removeCallbacks(longPressRunnable)
                // Historical samples keep a fast stroke smooth; MotionEvent
                // batches them between vsyncs and dropping them visibly
                // straightens curves under a stylus.
                for (h in 0 until event.historySize) {
                    sink.touch(TouchPhase.MOVED, pointersOf(event, h))
                }
                sink.touch(TouchPhase.MOVED, pointersOf(event))
            }

            Mode.SCROLL -> {
                val density = densityProvider().coerceAtLeast(0.1f)
                val cx = centroidX(event)
                val cy = centroidY(event)
                val dx = (cx - lastCentroidX) / density
                val dy = (cy - lastCentroidY) / density
                lastCentroidX = cx
                lastCentroidY = cy
                if (dx != 0f || dy != 0f) {
                    sink.scroll(normalizedX(cx), normalizedY(cy), dx, dy, ScrollPhase.CHANGED)
                }
            }

            Mode.RIGHT_CLICK ->
                sink.pointer(
                    PointerKind.MOVE,
                    PointerButton.RIGHT,
                    normalizedX(event.x),
                    normalizedY(event.y),
                )

            Mode.IDLE, Mode.DRAINING -> Unit
        }
        return true
    }

    private fun onSecondaryUp(event: MotionEvent): Boolean {
        if (mode == Mode.SCROLL && event.pointerCount <= 2) {
            sink.scroll(
                normalizedX(lastCentroidX),
                normalizedY(lastCentroidY),
                0f,
                0f,
                ScrollPhase.ENDED,
            )
            // The remaining finger must not become a new drag: the user is
            // still lifting out of a two-finger gesture.
            mode = Mode.DRAINING
            return true
        }
        if (mode == Mode.TOUCH) sink.touch(TouchPhase.ENDED, pointersOf(event, liftedIndex = event.actionIndex))
        return true
    }

    private fun onPrimaryUp(event: MotionEvent): Boolean {
        handler.removeCallbacks(longPressRunnable)
        when (mode) {
            Mode.TOUCH -> sink.touch(TouchPhase.ENDED, pointersOf(event))
            Mode.RIGHT_CLICK ->
                sink.pointer(
                    PointerKind.UP,
                    PointerButton.RIGHT,
                    normalizedX(event.x),
                    normalizedY(event.y),
                )

            Mode.SCROLL ->
                sink.scroll(
                    normalizedX(lastCentroidX),
                    normalizedY(lastCentroidY),
                    0f,
                    0f,
                    ScrollPhase.ENDED,
                )

            Mode.IDLE, Mode.DRAINING -> Unit
        }
        mode = Mode.IDLE
        return true
    }

    private fun onCancel(): Boolean {
        reset()
        return true
    }

    private fun promoteToRightClick() {
        if (mode != Mode.TOUCH) return
        // Take the drag back before the host can act on it, then press the
        // right button where the finger still rests.
        sink.touch(TouchPhase.CANCELLED, emptyList())
        mode = Mode.RIGHT_CLICK
        val x = normalizedX(downX)
        val y = normalizedY(downY)
        lastCentroidX = x
        lastCentroidY = y
        sink.pointer(PointerKind.DOWN, PointerButton.RIGHT, x, y)
    }

    private fun movedBeyondSlop(event: MotionEvent): Boolean {
        val dx = event.x - downX
        val dy = event.y - downY
        return dx * dx + dy * dy > touchSlopPx * touchSlopPx
    }

    // -------------------------------------------------------------------- mouse

    /** Hover, wheel and button events from a mouse or trackpad. */
    fun onGenericMotionEvent(event: MotionEvent): Boolean {
        if (!isMouse(event)) return false
        return when (event.actionMasked) {
            MotionEvent.ACTION_HOVER_MOVE, MotionEvent.ACTION_HOVER_ENTER -> {
                sink.pointer(
                    PointerKind.MOVE,
                    PointerButton.LEFT,
                    normalizedX(event.x),
                    normalizedY(event.y),
                )
                true
            }

            MotionEvent.ACTION_SCROLL -> {
                onWheel(event)
                true
            }

            MotionEvent.ACTION_BUTTON_PRESS -> {
                sink.pointer(
                    PointerKind.DOWN,
                    buttonOf(event.actionButton),
                    normalizedX(event.x),
                    normalizedY(event.y),
                )
                true
            }

            MotionEvent.ACTION_BUTTON_RELEASE -> {
                sink.pointer(
                    PointerKind.UP,
                    buttonOf(event.actionButton),
                    normalizedX(event.x),
                    normalizedY(event.y),
                )
                true
            }

            else -> false
        }
    }

    private fun onMouseTouch(event: MotionEvent): Boolean =
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE, MotionEvent.ACTION_UP -> {
                // Button press and release arrive separately as ACTION_BUTTON_*;
                // this path only has to keep the cursor position current.
                sink.pointer(
                    PointerKind.MOVE,
                    PointerButton.LEFT,
                    normalizedX(event.x),
                    normalizedY(event.y),
                )
                true
            }

            else -> false
        }

    private fun onWheel(event: MotionEvent) {
        val x = normalizedX(event.x)
        val y = normalizedY(event.y)
        lastCentroidX = x
        lastCentroidY = y
        if (!wheelActive) {
            wheelActive = true
            sink.scroll(x, y, 0f, 0f, ScrollPhase.BEGIN)
        }
        handler.removeCallbacks(wheelEndRunnable)
        val dx = -event.getAxisValue(MotionEvent.AXIS_HSCROLL) * WHEEL_NOTCH_POINTS
        val dy = -event.getAxisValue(MotionEvent.AXIS_VSCROLL) * WHEEL_NOTCH_POINTS
        sink.scroll(x, y, dx, dy, ScrollPhase.CHANGED)
        handler.postDelayed(wheelEndRunnable, WHEEL_END_DELAY_MS)
    }

    private fun buttonOf(actionButton: Int): Byte =
        when (actionButton) {
            MotionEvent.BUTTON_SECONDARY -> PointerButton.RIGHT
            MotionEvent.BUTTON_TERTIARY -> PointerButton.MIDDLE
            else -> PointerButton.LEFT
        }

    private fun isMouse(event: MotionEvent): Boolean =
        event.isFromSource(InputDevice.SOURCE_MOUSE) ||
            event.isFromSource(InputDevice.SOURCE_MOUSE_RELATIVE) ||
            event.getToolType(0) == MotionEvent.TOOL_TYPE_MOUSE

    // ----------------------------------------------------------------- keyboard

    /** Forwards a hardware key press; returns false for keys we keep locally. */
    fun onKeyEvent(event: AndroidKeyEvent): Boolean {
        if (KeyMapper.isLocalKey(event.keyCode)) return false
        if (event.action != AndroidKeyEvent.ACTION_DOWN && event.action != AndroidKeyEvent.ACTION_UP) {
            return false
        }
        val unicode = event.unicodeChar
        sink.key(
            KeyEvent(
                down = event.action == AndroidKeyEvent.ACTION_DOWN,
                keyCode = KeyMapper.virtualKeyCode(event.keyCode),
                text = if (unicode != 0) String(Character.toChars(unicode)) else "",
                mods = KeyMapper.modifiers(event.metaState),
            ),
        )
        return true
    }

    // ---------------------------------------------------------------- geometry

    private fun normalizedX(viewX: Float): Float = viewportProvider().normalizedX(viewX)

    private fun normalizedY(viewY: Float): Float = viewportProvider().normalizedY(viewY)

    private fun centroidX(event: MotionEvent): Float {
        var sum = 0f
        for (i in 0 until event.pointerCount) sum += event.getX(i)
        return sum / event.pointerCount
    }

    private fun centroidY(event: MotionEvent): Float {
        var sum = 0f
        for (i in 0 until event.pointerCount) sum += event.getY(i)
        return sum / event.pointerCount
    }

    /**
     * Snapshots the pointers of [event], optionally from historical sample
     * [historyIndex] and skipping the pointer at [liftedIndex].
     */
    private fun pointersOf(
        event: MotionEvent,
        historyIndex: Int = -1,
        liftedIndex: Int = -1,
    ): List<TouchPointer> {
        val viewport = viewportProvider()
        val pointers = ArrayList<TouchPointer>(event.pointerCount)
        for (i in 0 until event.pointerCount) {
            if (i == liftedIndex) continue
            val historical = historyIndex >= 0
            val x = if (historical) event.getHistoricalX(i, historyIndex) else event.getX(i)
            val y = if (historical) event.getHistoricalY(i, historyIndex) else event.getY(i)
            val pressure =
                if (historical) event.getHistoricalPressure(i, historyIndex) else event.getPressure(i)
            val toolType = event.getToolType(i)
            val isStylus =
                toolType == MotionEvent.TOOL_TYPE_STYLUS || toolType == MotionEvent.TOOL_TYPE_ERASER
            val tilt =
                if (isStylus) {
                    if (historical) {
                        event.getHistoricalAxisValue(MotionEvent.AXIS_TILT, i, historyIndex)
                    } else {
                        event.getAxisValue(MotionEvent.AXIS_TILT, i)
                    }
                } else {
                    0f
                }
            val azimuth =
                if (isStylus) {
                    if (historical) {
                        event.getHistoricalOrientation(i, historyIndex)
                    } else {
                        event.getOrientation(i)
                    }
                } else {
                    0f
                }
            pointers.add(
                TouchPointer(
                    pointerId = event.getPointerId(i),
                    tool = if (isStylus) TouchTool.STYLUS else TouchTool.FINGER,
                    x = viewport.normalizedX(x),
                    y = viewport.normalizedY(y),
                    pressure = pressure.coerceIn(0f, 1f),
                    // Android reports one tilt off the panel normal plus an
                    // azimuth; the wire wants the pair decomposed along the
                    // screen axes, in radians. See docs/VECTORS.md.
                    tiltX = (tilt * kotlin.math.sin(azimuth.toDouble())).toFloat(),
                    tiltY = (-tilt * kotlin.math.cos(azimuth.toDouble())).toFloat(),
                    azimuth = azimuth,
                ),
            )
        }
        return pointers
    }

    private companion object {
        const val DEFAULT_TOUCH_SLOP_PX = 16f

        /** One wheel notch in points, matching a macOS line scroll. */
        const val WHEEL_NOTCH_POINTS = 16f
        const val WHEEL_END_DELAY_MS = 150L
    }
}
