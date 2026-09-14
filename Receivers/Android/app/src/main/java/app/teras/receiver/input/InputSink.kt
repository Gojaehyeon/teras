package app.teras.receiver.input

import app.teras.receiver.net.KeyEvent
import app.teras.receiver.net.TouchPointer

/** Where translated input events go — in production, the live session. */
interface InputSink {
    fun touch(phase: Byte, pointers: List<TouchPointer>)

    fun scroll(x: Float, y: Float, dx: Float, dy: Float, phase: Byte)

    fun pointer(kind: Byte, button: Byte, x: Float, y: Float)

    fun key(event: KeyEvent)
}
