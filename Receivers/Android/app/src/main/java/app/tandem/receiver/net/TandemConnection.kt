package app.tandem.receiver.net

import android.util.Log
import app.tandem.receiver.crypto.SessionCipher
import app.tandem.receiver.crypto.SessionCipherException
import app.tandem.receiver.store.PairedHostStore
import java.io.EOFException
import java.io.IOException
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Supplies the periodic STATS payload; null skips a tick. */
fun interface StatsSource {
    fun snapshot(rttMs: Double): StatsSnapshot?
}

/**
 * One host session: the socket, the frame codecs, the ENC envelope, the
 * heartbeat and the STATS ticker (PROTOCOL.md §2.1, §7, §8).
 *
 * A connection is used once. [close] is idempotent and always reached, so no
 * thread or socket outlives the session.
 */
class TandemConnection(
    private val socket: Socket,
    store: PairedHostStore,
    profileProvider: () -> DeviceProfile,
    private val listener: SessionListener,
    private val statsSource: StatsSource,
    private val onClosed: (TandemConnection, String) -> Unit,
) : SessionOutput, SessionListener {
    private val reader = FrameReader(socket.getInputStream())
    private val writer = FrameWriter(socket.getOutputStream())

    private val sendLock = Any()
    private var cipher: SessionCipher? = null

    private val closed = AtomicBoolean(false)
    private var readerThread: Thread? = null
    private var timers: ScheduledExecutorService? = null

    @Volatile private var lastPongAtNanos: Long = System.nanoTime()

    @Volatile private var rttMicros: Long = 0

    val session =
        SessionStateMachine(
            store = store,
            profileProvider = profileProvider,
            output = this,
            listener = this,
            peerIsLoopback = socket.inetAddress?.isLoopbackAddress ?: false,
        )

    val peerDescription: String = socket.inetAddress?.hostAddress ?: "unknown"

    val roundTripMs: Double get() = rttMicros / 1000.0

    fun start() {
        socket.tcpNoDelay = true
        socket.keepAlive = true
        lastPongAtNanos = System.nanoTime()

        readerThread =
            Thread({ readLoop() }, "tandem-reader").apply {
                isDaemon = true
                start()
            }

        timers =
            Executors.newSingleThreadScheduledExecutor { r ->
                Thread(r, "tandem-timers").apply { isDaemon = true }
            }.also { executor ->
                executor.scheduleAtFixedRate(
                    ::heartbeatTick,
                    Protocol.PING_INTERVAL_MS,
                    Protocol.PING_INTERVAL_MS,
                    TimeUnit.MILLISECONDS,
                )
                executor.scheduleAtFixedRate(
                    ::statsTick,
                    Protocol.STATS_INTERVAL_MS,
                    Protocol.STATS_INTERVAL_MS,
                    TimeUnit.MILLISECONDS,
                )
            }
    }

    private fun readLoop() {
        var reason = "connection ended"
        try {
            while (!closed.get()) {
                val frame = reader.readFrame()
                val armed = synchronized(sendLock) { cipher }
                if (armed != null) {
                    if (frame.type != MessageType.ENC) {
                        throw ProtocolException(
                            "plaintext ${MessageType.name(frame.type)} after the envelope was armed",
                        )
                    }
                    val (innerType, innerPayload) = armed.open(frame.payload)
                    session.handle(innerType, innerPayload)
                } else {
                    if (frame.type == MessageType.ENC) {
                        throw ProtocolException("ENC frame before AUTH_OK")
                    }
                    session.handle(frame.type, frame.payload)
                }
            }
        } catch (_: EOFException) {
            reason = "host closed the connection"
        } catch (e: SessionCipherException) {
            reason = "encryption error: ${e.message}"
            Log.w(TAG, reason)
        } catch (e: ProtocolException) {
            reason = "protocol error: ${e.message}"
            Log.w(TAG, reason)
        } catch (e: IOException) {
            reason = if (closed.get()) "connection closed" else "socket error: ${e.message}"
        } catch (e: Exception) {
            reason = "unexpected error: ${e.message}"
            Log.e(TAG, "reader loop failed", e)
        } finally {
            close(reason)
        }
    }

    private fun heartbeatTick() {
        if (closed.get()) return
        val sinceLastPong = System.nanoTime() - lastPongAtNanos
        if (sinceLastPong > TimeUnit.MILLISECONDS.toNanos(Protocol.PONG_TIMEOUT_MS)) {
            close("no PONG for ${Protocol.PONG_TIMEOUT_MS} ms")
            return
        }
        try {
            session.sendPing(System.nanoTime() / 1_000L)
        } catch (e: IOException) {
            close("ping failed: ${e.message}")
        }
    }

    private fun statsTick() {
        if (closed.get()) return
        if (session.state != SessionState.STREAMING && session.state != SessionState.READY) return
        val snapshot = statsSource.snapshot(roundTripMs) ?: return
        try {
            session.sendStats(snapshot)
        } catch (e: IOException) {
            close("stats failed: ${e.message}")
        }
    }

    // ------------------------------------------------------------ SessionOutput

    override fun send(type: Byte, payload: ByteArray) {
        if (closed.get()) return
        // Socket writes must never run on the UI thread (NetworkOnMainThread);
        // the surface-attach path asks for a keyframe from a Choreographer
        // callback, so hop onto the single writer thread there. Off the main
        // thread the write stays synchronous so ordering guarantees hold.
        if (isOnMainThread()) {
            writerExecutor.execute { writeLocked(type, payload) }
            return
        }
        writeLocked(type, payload)
    }

    private fun isOnMainThread(): Boolean =
        runCatching { android.os.Looper.getMainLooper()?.isCurrentThread == true }.getOrDefault(false)

    private val writerExecutor = java.util.concurrent.Executors.newSingleThreadExecutor { r ->
        Thread(r, "tandem-writer").apply { isDaemon = true }
    }

    private fun writeLocked(type: Byte, payload: ByteArray) {
        if (closed.get()) return
        try {
            // The cipher lookup and the write are one critical section: arming
            // must not interleave with an in-flight plaintext write, or the host
            // would see an unencrypted frame after AUTH_OK.
            synchronized(sendLock) {
                val armed = cipher
                if (armed != null) {
                    writer.writeFrame(MessageType.ENC, armed.seal(type, payload))
                } else {
                    writer.writeFrame(type, payload)
                }
            }
        } catch (e: IOException) {
            close("write failed: ${e.message}")
        }
    }

    override fun armEncryption(cipher: SessionCipher) {
        synchronized(sendLock) { this.cipher = cipher }
    }

    override fun close(reason: String) {
        if (!closed.compareAndSet(false, true)) return
        Log.i(TAG, "closing session with $peerDescription: $reason")
        timers?.shutdownNow()
        timers = null
        writerExecutor.shutdown()
        try {
            socket.close()
        } catch (_: IOException) {
            // Already gone; nothing to recover.
        }
        val thread = readerThread
        readerThread = null
        if (thread != null && thread !== Thread.currentThread()) {
            thread.interrupt()
            thread.join(SHUTDOWN_JOIN_MS)
        }
        onClosed(this, reason)
    }

    /** Best-effort BYE before a deliberate teardown. */
    fun shutdownGracefully(reason: String) {
        if (closed.get()) return
        try {
            session.sendBye(reason)
        } catch (_: Exception) {
            // The socket may already be dead; closing is what matters.
        }
        close(reason)
    }

    val isClosed: Boolean get() = closed.get()

    // ---------------------------------------------------------- SessionListener

    override fun onHello(hello: Hello) = listener.onHello(hello)

    override fun onPinRequired(pin: String, attemptsLeft: Int) = listener.onPinRequired(pin, attemptsLeft)

    override fun onPinDismissed() = listener.onPinDismissed()

    override fun onPaired(hostId: String) = listener.onPaired(hostId)

    override fun onAuthenticated(hostId: String, encrypted: Boolean) =
        listener.onAuthenticated(hostId, encrypted)

    override fun onStreamConfig(config: StreamConfig) = listener.onStreamConfig(config)

    override fun onVideo(frame: VideoFrame) = listener.onVideo(frame)

    override fun onRoundTrip(rttMicros: Long, hostClockOffsetMicros: Long) {
        lastPongAtNanos = System.nanoTime()
        this.rttMicros = rttMicros
        listener.onRoundTrip(rttMicros, hostClockOffsetMicros)
    }

    override fun onBye(reason: String) = listener.onBye(reason)

    override fun onProtocolError(message: String) = listener.onProtocolError(message)

    private companion object {
        const val TAG = "TandemConnection"
        const val SHUTDOWN_JOIN_MS = 500L
    }
}
