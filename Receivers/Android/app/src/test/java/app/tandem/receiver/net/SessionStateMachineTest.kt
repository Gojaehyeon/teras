package app.tandem.receiver.net

import app.tandem.receiver.crypto.PairingCrypto
import app.tandem.receiver.crypto.SessionCipher
import app.tandem.receiver.store.InMemoryHostStore
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The lifecycle of PROTOCOL.md §3 and §8, driven as the Mac host would drive it. */
class SessionStateMachineTest {
    private val hostId = "11111111-1111-1111-1111-111111111111"
    private val deviceId = "22222222-2222-2222-2222-222222222222"
    private val hostNonce = ByteArray(16) { 0x01 }
    private val deviceNonce = ByteArray(16) { 0x02 }
    private val fixedSecret = ByteArray(32) { 0x03 }
    private val pin = "123456"

    private val store = InMemoryHostStore(deviceId)
    private val output = RecordingOutput()
    private val listener = RecordingListener()

    private fun machine(peerIsLoopback: Boolean = false) =
        SessionStateMachine(
            store = store,
            profileProvider = ::profile,
            output = output,
            listener = listener,
            peerIsLoopback = peerIsLoopback,
            pinGenerator = { pin },
            nonceGenerator = { deviceNonce },
            secretGenerator = { fixedSecret },
        )

    private fun profile() =
        DeviceProfile(
            deviceId = deviceId,
            deviceName = "Pixel 8",
            model = "Google Pixel 8",
            screen = ScreenInfo(1080, 2400, 2.625f, 120, SafeInsets(120, 48, 0, 0)),
            orientation = Orientation.PORTRAIT,
            codecs = listOf("hevc", "h264"),
            maxDecodeWidth = 4096,
            maxDecodeHeight = 2304,
            features = listOf("touch", "pencil", "keyboard", "scroll", "hover"),
        )

    private fun helloPayload(transport: String, encrypt: Boolean = false): ByteArray =
        JSONObject()
            .put("pv", 1)
            .put("hostId", hostId)
            .put("hostName", "Go's MacBook Pro")
            .put("transport", transport)
            .put("hostNonce", Json.encodeBase64(hostNonce))
            .put("encrypt", encrypt)
            .put("app", JSONObject().put("name", "Tandem").put("version", "1.0.0").put("build", 12))
            .toString()
            .toByteArray()

    private fun streamConfigPayload(codec: String = "hevc", w: Int = 2556, h: Int = 1179): ByteArray =
        JSONObject()
            .put("codec", codec)
            .put("wPx", w)
            .put("hPx", h)
            .put("fps", 60)
            .put("desktop", JSONObject().put("w", 1278).put("h", 589))
            .put("orientation", "landscapeLeft")
            .put("mode", "extend")
            .put("cursorBaked", true)
            .toString()
            .toByteArray()

    // -------------------------------------------------------------------- USB

    @Test
    fun `a usb session skips pairing and reaches streaming`() {
        val session = machine(peerIsLoopback = true)
        session.handle(MessageType.HELLO, helloPayload("usb"))

        assertEquals(SessionState.AWAITING_STREAM_CONFIG, session.state)
        val ack = JSONObject(String(output.last().payload))
        assertFalse(ack.getBoolean("authRequired"))
        assertFalse(ack.getBoolean("paired"))
        assertEquals("android", ack.getString("platform"))
        assertEquals(deviceId, ack.getString("deviceId"))
        assertEquals(1, ack.getInt("pv"))
        assertEquals(1080, ack.getJSONObject("screen").getInt("wPx"))
        assertEquals(120, ack.getJSONObject("screen").getInt("refreshHz"))
        assertEquals(48, ack.getJSONObject("screen").getJSONObject("safeInsets").getInt("bottom"))

        session.handle(MessageType.STREAM_CONFIG, streamConfigPayload())
        assertEquals(MessageType.READY, output.last().type)
        assertEquals(SessionState.READY, session.state)
        assertEquals("hevc", listener.streamConfig?.codec)

        session.handle(
            MessageType.VIDEO,
            VideoFrame.encode(VideoFrame.FLAG_KEYFRAME, 99L, 1, byteArrayOf(0, 0, 0, 1, 0x26)),
        )
        assertEquals(SessionState.STREAMING, session.state)
        assertEquals(1, listener.videoFrames.size)
        assertNull(output.closeReason)
    }

    @Test
    fun `a lan peer claiming usb transport still has to authenticate`() {
        val session = machine(peerIsLoopback = false)
        session.handle(MessageType.HELLO, helloPayload("usb"))

        // HELLO_ACK is followed straight away by PAIR_REQUIRED, so pick it out
        // by type rather than taking the last frame.
        val ack = JSONObject(String(output.firstOf(MessageType.HELLO_ACK)!!.payload))
        assertTrue(ack.getBoolean("authRequired"))
        assertEquals(SessionState.AWAITING_PAIR, session.state)
    }

    // ---------------------------------------------------------------- pairing

    @Test
    fun `an unpaired lan host pairs then authenticates`() {
        val session = machine()
        session.handle(MessageType.HELLO, helloPayload("lan", encrypt = true))

        assertEquals(SessionState.AWAITING_PAIR, session.state)
        assertEquals(pin, listener.pin)
        val required = output.firstOf(MessageType.PAIR_REQUIRED)!!
        assertEquals(3, JSONObject(String(required.payload)).getInt("attemptsLeft"))

        val pinKey = PairingCrypto.pinKey(pin, deviceId, hostId)
        session.handle(MessageType.PAIR, proofPayload(PairingCrypto.pairProof(pinKey, hostNonce, deviceNonce)))

        assertEquals(SessionState.AWAITING_AUTH, session.state)
        assertTrue(listener.pinDismissed)
        assertEquals(hostId, listener.pairedHostId)

        // The host decrypts the box with the same PIN and gets the secret.
        val box = java.util.Base64.getDecoder().decode(
            JSONObject(String(output.last().payload)).getString("box"),
        )
        val recovered = PairingCrypto.openPairBox(pinKey, hostNonce, deviceNonce, box)
        assertArrayEquals(fixedSecret, recovered)
        assertArrayEquals(fixedSecret, store.secretFor(hostId))

        session.handle(
            MessageType.AUTH,
            proofPayload(PairingCrypto.authProof(recovered, hostNonce, deviceNonce)),
        )
        assertEquals(SessionState.AWAITING_STREAM_CONFIG, session.state)

        val ackProof = java.util.Base64.getDecoder().decode(
            JSONObject(String(output.firstOf(MessageType.AUTH_OK)!!.payload)).getString("proof"),
        )
        assertArrayEquals(
            PairingCrypto.authAckProof(recovered, hostNonce, deviceNonce),
            ackProof,
        )
        assertNotNull(output.armedCipher)
        assertTrue(listener.authenticatedEncrypted)
    }

    @Test
    fun `three wrong pins close the session and rotate the pin`() {
        val session = machine()
        session.handle(MessageType.HELLO, helloPayload("lan"))
        val wrong = proofPayload(ByteArray(32) { 0x55 })

        session.handle(MessageType.PAIR, wrong)
        assertEquals(2, JSONObject(String(output.last().payload)).getInt("attemptsLeft"))
        assertFalse(JSONObject(String(output.last().payload)).getBoolean("locked"))

        session.handle(MessageType.PAIR, wrong)
        assertEquals(1, JSONObject(String(output.last().payload)).getInt("attemptsLeft"))

        var rotations = 0
        val rotating =
            SessionStateMachine(
                store = InMemoryHostStore(deviceId),
                profileProvider = ::profile,
                output = output,
                listener = listener,
                peerIsLoopback = false,
                pinGenerator = { "%06d".format(rotations++) },
                nonceGenerator = { deviceNonce },
                secretGenerator = { fixedSecret },
            )
        rotating.handle(MessageType.HELLO, helloPayload("lan"))
        repeat(3) { rotating.handle(MessageType.PAIR, wrong) }

        val failure = JSONObject(String(output.sent.last { it.type == MessageType.PAIR_FAIL }.payload))
        assertEquals(0, failure.getInt("attemptsLeft"))
        assertTrue(failure.getBoolean("locked"))
        assertEquals(SessionState.CLOSED, rotating.state)
        assertNotNull(output.closeReason)
        // The PIN a watcher saw is no longer the live one.
        assertEquals(2, rotations)
    }

    @Test
    fun `a paired host goes straight to auth`() {
        store.store(hostId, fixedSecret)
        val session = machine()
        session.handle(MessageType.HELLO, helloPayload("lan"))

        assertEquals(SessionState.AWAITING_AUTH, session.state)
        assertTrue(JSONObject(String(output.last().payload)).getBoolean("paired"))
        assertNull(listener.pin)
    }

    @Test
    fun `a wrong auth proof fails without discarding the stored secret`() {
        store.store(hostId, fixedSecret)
        val session = machine()
        session.handle(MessageType.HELLO, helloPayload("lan"))
        session.handle(MessageType.AUTH, proofPayload(ByteArray(32)))

        assertEquals(MessageType.AUTH_FAIL, output.sent.last { it.type == MessageType.AUTH_FAIL }.type)
        assertEquals(SessionState.CLOSED, session.state)
        assertArrayEquals(fixedSecret, store.secretFor(hostId))
    }

    @Test
    fun `a host that lost its secret can restart pairing from the auth state`() {
        store.store(hostId, fixedSecret)
        val session = machine()
        session.handle(MessageType.HELLO, helloPayload("lan"))
        assertEquals(SessionState.AWAITING_AUTH, session.state)

        session.handle(MessageType.PAIR, proofPayload(ByteArray(32)))

        assertEquals(SessionState.AWAITING_PAIR, session.state)
        assertEquals(pin, listener.pin)
        assertNotNull(output.firstOf(MessageType.PAIR_REQUIRED))
    }

    @Test
    fun `no encryption is armed when the host did not ask for it`() {
        store.store(hostId, fixedSecret)
        val session = machine()
        session.handle(MessageType.HELLO, helloPayload("lan", encrypt = false))
        session.handle(
            MessageType.AUTH,
            proofPayload(PairingCrypto.authProof(fixedSecret, hostNonce, deviceNonce)),
        )

        assertEquals(SessionState.AWAITING_STREAM_CONFIG, session.state)
        assertNull(output.armedCipher)
        assertFalse(listener.authenticatedEncrypted)
    }

    @Test
    fun `the armed cipher opens what a matching host cipher seals`() {
        store.store(hostId, fixedSecret)
        val session = machine()
        session.handle(MessageType.HELLO, helloPayload("lan", encrypt = true))
        session.handle(
            MessageType.AUTH,
            proofPayload(PairingCrypto.authProof(fixedSecret, hostNonce, deviceNonce)),
        )

        val host = SessionCipher.forHost(fixedSecret, hostNonce, deviceNonce)
        val (type, payload) = output.armedCipher!!.open(host.seal(MessageType.PING, ByteArray(8)))
        assertEquals(MessageType.PING, type)
        assertEquals(8, payload.size)
    }

    // ------------------------------------------------------------- lifecycle

    @Test
    fun `ping is answered with a pong that echoes the send stamp`() {
        val session = machine(peerIsLoopback = true)
        session.handle(MessageType.HELLO, helloPayload("usb"))
        session.handle(MessageType.PING, InputCodec.encodePing(4242L))

        val pong = output.sent.last { it.type == MessageType.PONG }
        val (echo, receivedAt) = InputCodec.decodePong(pong.payload)
        assertEquals(4242L, echo)
        assertTrue(receivedAt > 0L)
    }

    @Test
    fun `a pong yields a round trip and a clock offset`() {
        val session = machine(peerIsLoopback = true)
        session.handle(MessageType.HELLO, helloPayload("usb"))
        val sentAt = System.nanoTime() / 1_000L
        session.handle(MessageType.PONG, InputCodec.encodePong(sentAt, sentAt + 1_000_000L))

        assertNotNull(listener.rttMicros)
        assertTrue(listener.rttMicros!! >= 0)
        assertNotNull(listener.clockOffsetMicros)
    }

    @Test
    fun `bye closes the session`() {
        val session = machine(peerIsLoopback = true)
        session.handle(MessageType.HELLO, helloPayload("usb"))
        session.handle(MessageType.BYE, """{"reason":"user quit"}""".toByteArray())

        assertEquals("user quit", listener.byeReason)
        assertEquals(SessionState.CLOSED, session.state)
        assertEquals("user quit", output.closeReason)
    }

    @Test
    fun `an unknown message type is skipped`() {
        val session = machine(peerIsLoopback = true)
        session.handle(MessageType.HELLO, helloPayload("usb"))
        val before = output.sent.size

        session.handle(0x6E.toByte(), byteArrayOf(1, 2, 3))

        assertEquals(before, output.sent.size)
        assertEquals(SessionState.AWAITING_STREAM_CONFIG, session.state)
        assertNull(output.closeReason)
    }

    @Test
    fun `stream config before the handshake is a protocol error`() {
        val session = machine()
        session.handle(MessageType.STREAM_CONFIG, streamConfigPayload())

        assertEquals(SessionState.CLOSED, session.state)
        assertNotNull(listener.protocolError)
    }

    @Test
    fun `a second hello is a protocol error`() {
        val session = machine(peerIsLoopback = true)
        session.handle(MessageType.HELLO, helloPayload("usb"))
        session.handle(MessageType.HELLO, helloPayload("usb"))

        assertEquals(SessionState.CLOSED, session.state)
        assertNotNull(listener.protocolError)
    }

    @Test
    fun `a hello with a short nonce is rejected`() {
        val payload =
            JSONObject()
                .put("pv", 1)
                .put("hostId", hostId)
                .put("transport", "usb")
                .put("hostNonce", Json.encodeBase64(ByteArray(8)))
                .toString()
                .toByteArray()

        val session = machine(peerIsLoopback = true)
        session.handle(MessageType.HELLO, payload)

        assertEquals(SessionState.CLOSED, session.state)
        assertNotNull(listener.protocolError)
    }

    @Test
    fun `outbound helpers produce the documented payloads`() {
        val session = machine(peerIsLoopback = true)
        session.handle(MessageType.HELLO, helloPayload("usb"))

        session.sendKeyframeRequest()
        assertEquals(0, output.last().payload.size)

        session.sendDeviceConfig(
            Orientation.LANDSCAPE_RIGHT,
            ScreenInfo(2400, 1080, 2.625f, 120, SafeInsets.ZERO),
        )
        val deviceConfig = JSONObject(String(output.last().payload))
        assertEquals("landscapeRight", deviceConfig.getString("orientation"))
        assertEquals(2400, deviceConfig.getJSONObject("screen").getInt("wPx"))

        session.sendStats(StatsSnapshot(59.84, 0.0, 3.14, 1, 2.42, 18.51))
        val stats = JSONObject(String(output.last().payload))
        assertEquals(59.8, stats.getDouble("fpsDecoded"), 0.001)
        assertEquals(3.1, stats.getDouble("decodeMsP50"), 0.001)
        assertEquals(1, stats.getInt("queued"))

        session.sendKey(KeyEvent(down = true, keyCode = 0, text = "a", mods = listOf("cmd")))
        val key = JSONObject(String(output.last().payload))
        assertTrue(key.getBoolean("down"))
        assertEquals("a", key.getString("text"))
        assertEquals("cmd", key.getJSONArray("mods").getString(0))
    }

    private fun proofPayload(proof: ByteArray): ByteArray =
        JSONObject().put("proof", Json.encodeBase64(proof)).toString().toByteArray()
}
