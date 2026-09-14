package app.tandem.receiver.net

import android.util.Log
import app.tandem.receiver.store.PairedHostStore
import java.io.IOException
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The listening half of PROTOCOL.md §1: the receiver owns the socket on port
 * 41777 and the Mac dials in, over adb's loopback forward for USB or over the
 * LAN address advertised by Bonjour.
 *
 * Exactly one session is served at a time; a new inbound connection replaces
 * the old one, which is torn down first so the decoder starts from a clean state.
 */
class TandemServer(
    private val store: PairedHostStore,
    private val profileProvider: () -> DeviceProfile,
    private val listener: SessionListener,
    private val statsSource: StatsSource,
    private val port: Int = Protocol.PORT,
) {
    private val running = AtomicBoolean(false)
    private var serverSocket: ServerSocket? = null
    private var acceptThread: Thread? = null

    @Volatile private var current: TandemConnection? = null

    /** Called on the accept thread when a session starts or ends. */
    var onSessionStarted: ((TandemConnection) -> Unit)? = null
    var onSessionEnded: ((TandemConnection, String) -> Unit)? = null
    var onListenFailed: ((Throwable) -> Unit)? = null

    val activeConnection: TandemConnection? get() = current

    val boundPort: Int get() = serverSocket?.localPort ?: port

    /** True once the socket is bound and the accept loop is running. */
    val isListening: Boolean get() = running.get() && serverSocket?.isBound == true

    fun start() {
        if (!running.compareAndSet(false, true)) return
        val server =
            try {
                ServerSocket().apply {
                    reuseAddress = true
                    bind(InetSocketAddress(port), BACKLOG)
                }
            } catch (e: IOException) {
                running.set(false)
                Log.e(TAG, "cannot bind port $port", e)
                onListenFailed?.invoke(e)
                return
            }
        serverSocket = server
        acceptThread =
            Thread({ acceptLoop(server) }, "tandem-accept").apply {
                isDaemon = true
                start()
            }
        Log.i(TAG, "listening on port ${server.localPort}")
    }

    private fun acceptLoop(server: ServerSocket) {
        while (running.get()) {
            val socket =
                try {
                    server.accept()
                } catch (e: IOException) {
                    if (running.get()) {
                        Log.e(TAG, "accept failed", e)
                        onListenFailed?.invoke(e)
                    }
                    return
                }
            try {
                adopt(socket)
            } catch (e: IOException) {
                Log.w(TAG, "could not start session", e)
                closeQuietly(socket)
            }
        }
    }

    private fun adopt(socket: Socket) {
        current?.shutdownGracefully("replaced by a new host connection")

        val connection =
            TandemConnection(
                socket = socket,
                store = store,
                profileProvider = profileProvider,
                listener = listener,
                statsSource = statsSource,
                onClosed = { conn, reason ->
                    if (current === conn) current = null
                    onSessionEnded?.invoke(conn, reason)
                },
            )
        current = connection
        connection.start()
        onSessionStarted?.invoke(connection)
    }

    fun stop() {
        if (!running.compareAndSet(true, false)) return
        current?.shutdownGracefully("receiver stopped listening")
        current = null
        try {
            serverSocket?.close()
        } catch (_: IOException) {
            // Closing is what unblocks accept(); a failure here is terminal anyway.
        }
        serverSocket = null
        acceptThread?.join(SHUTDOWN_JOIN_MS)
        acceptThread = null
    }

    private fun closeQuietly(socket: Socket) {
        try {
            socket.close()
        } catch (_: IOException) {
            // Nothing left to do for a socket we are already discarding.
        }
    }

    private companion object {
        const val TAG = "TandemServer"
        const val BACKLOG = 4
        const val SHUTDOWN_JOIN_MS = 500L
    }
}
