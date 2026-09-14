package app.tandem.receiver.net

import app.tandem.receiver.store.InMemoryHostStore
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.EOFException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The transport rules of PROTOCOL.md §1 and §7, exercised over a real loopback
 * socket rather than a stub: the heartbeat and the close-on-silence behaviour
 * only exist in [TandemConnection], not in the state machine.
 */
class TandemConnectionTest {
    private val sockets = mutableListOf<AutoCloseable>()
    private var connection: TandemConnection? = null

    @After
    fun tearDown() {
        connection?.close("test finished")
        sockets.forEach { runCatching { it.close() } }
    }

    private fun connectedPair(): Pair<Socket, Socket> {
        val server = ServerSocket(0, 1, InetAddress.getLoopbackAddress())
        sockets.add(server)
        val client = Socket(InetAddress.getLoopbackAddress(), server.localPort)
        val accepted = server.accept()
        sockets.add(client)
        sockets.add(accepted)
        return client to accepted
    }

    private fun startReceiver(
        accepted: Socket,
        listener: SessionListener = object : SessionListener {},
    ): TandemConnection {
        val conn =
            TandemConnection(
                socket = accepted,
                store = InMemoryHostStore("22222222-2222-2222-2222-222222222222"),
                profileProvider = ::profile,
                listener = listener,
                statsSource = { null },
                onClosed = { _, _ -> },
            )
        connection = conn
        conn.start()
        return conn
    }

    private fun profile() =
        DeviceProfile(
            deviceId = "22222222-2222-2222-2222-222222222222",
            deviceName = "Test device",
            model = "Test model",
            screen = ScreenInfo(1080, 2400, 2.625f, 60, SafeInsets.ZERO),
            orientation = Orientation.PORTRAIT,
            codecs = listOf("h264"),
            maxDecodeWidth = 1920,
            maxDecodeHeight = 1080,
            features = listOf("touch"),
        )

    private fun helloBytes(): ByteArray =
        JSONObject()
            .put("pv", 1)
            .put("hostId", "11111111-1111-1111-1111-111111111111")
            .put("hostName", "test host")
            .put("transport", "usb")
            .put("hostNonce", Json.encodeBase64(ByteArray(16) { 0x01 }))
            .put("encrypt", false)
            .toString()
            .toByteArray()

    @Test
    fun `the receiver answers HELLO and then pings on its own`() {
        val (client, accepted) = connectedPair()
        startReceiver(accepted)

        val writer = FrameWriter(client.getOutputStream())
        val reader = FrameReader(client.getInputStream())
        writer.writeFrame(MessageType.HELLO, helloBytes())

        val ack = reader.readFrame()
        assertEquals(MessageType.HELLO_ACK, ack.type)
        assertEquals("android", JSONObject(String(ack.payload)).getString("platform"))

        // PROTOCOL.md §7: the receiver pings once a second without being asked.
        client.soTimeout = 4_000
        val ping = reader.readFrame()
        assertEquals(MessageType.PING, ping.type)
        assertTrue(InputCodec.decodePing(ping.payload) > 0L)
    }

    @Test
    fun `a host that never answers PING is dropped`() {
        val (client, accepted) = connectedPair()
        val conn = startReceiver(accepted)

        FrameWriter(client.getOutputStream()).writeFrame(MessageType.HELLO, helloBytes())
        val reader = FrameReader(client.getInputStream())
        assertEquals(MessageType.HELLO_ACK, reader.readFrame().type)

        // Read and deliberately ignore whatever arrives until the peer gives up.
        client.soTimeout = 8_000
        val closed =
            try {
                while (true) reader.readFrame()
                false
            } catch (_: EOFException) {
                true
            } catch (_: Exception) {
                true
            }

        assertTrue("the receiver kept an unanswered connection open", closed)
        assertTrue(conn.isClosed)
    }

    @Test
    fun `an unknown frame type is skipped rather than closing the connection`() {
        val (client, accepted) = connectedPair()
        val conn = startReceiver(accepted)

        val writer = FrameWriter(client.getOutputStream())
        val reader = FrameReader(client.getInputStream())
        writer.writeFrame(MessageType.HELLO, helloBytes())
        assertEquals(MessageType.HELLO_ACK, reader.readFrame().type)

        // A type from a future protocol version, with a payload the receiver
        // cannot interpret. The length prefix makes skipping it safe.
        writer.writeFrame(0x6E.toByte(), ByteArray(64) { it.toByte() })
        writer.writeFrame(MessageType.PING, InputCodec.encodePing(1234L))

        client.soTimeout = 4_000
        var pong: Frame? = null
        while (pong == null) {
            val frame = reader.readFrame()
            if (frame.type == MessageType.PONG) pong = frame
        }

        assertEquals(1234L, InputCodec.decodePong(pong.payload).first)
        assertTrue("an unknown type closed the connection", !conn.isClosed)
    }

    @Test
    fun `a second host connection replaces the first`() {
        val store = InMemoryHostStore("22222222-2222-2222-2222-222222222222")
        val started = CountDownLatch(2)
        val server =
            TandemServer(
                store = store,
                profileProvider = ::profile,
                listener = object : SessionListener {},
                statsSource = { null },
                port = 0,
            )
        server.onSessionStarted = { started.countDown() }
        server.start()
        assertTrue(server.isListening)

        try {
            val first = Socket(InetAddress.getLoopbackAddress(), server.boundPort)
            sockets.add(first)
            FrameWriter(first.getOutputStream()).writeFrame(MessageType.HELLO, helloBytes())
            assertEquals(MessageType.HELLO_ACK, FrameReader(first.getInputStream()).readFrame().type)
            val firstConnection = server.activeConnection
            assertNotNull(firstConnection)

            val second = Socket(InetAddress.getLoopbackAddress(), server.boundPort)
            sockets.add(second)
            assertTrue(started.await(5, TimeUnit.SECONDS))

            // PROTOCOL.md §1: a receiver serves one host at a time and the new
            // connection wins.
            waitUntil(5_000) { firstConnection!!.isClosed }
            assertTrue(firstConnection!!.isClosed)
            assertTrue(server.activeConnection !== firstConnection)
        } finally {
            server.stop()
        }
    }

    private fun waitUntil(timeoutMs: Long, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline && !condition()) {
            Thread.sleep(25)
        }
    }
}
