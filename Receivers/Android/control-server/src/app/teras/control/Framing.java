package app.teras.control;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;

/**
 * Wire framing for Teras Control protocol v1 (docs/CONTROL.md section 3).
 *
 * <pre>[u16 length][u8 type][payload]</pre>
 *
 * big-endian, {@code length == 1 + payload.length}. This class deliberately
 * depends on nothing but {@code java.*} so it can be unit-tested on a desktop
 * JVM without an Android runtime.
 */
public final class Framing {

    /** {@code length} is a u16 that already counts the type byte. */
    public static final int MAX_PAYLOAD = 65535 - 1;

    // ---- Mac -> server -------------------------------------------------
    public static final int HELLO = 0x01;
    public static final int POINTER_MOVE = 0x10;
    public static final int BUTTON = 0x11;
    public static final int SCROLL = 0x12;
    public static final int KEY = 0x20;
    public static final int TEXT = 0x21;
    public static final int GET_DISPLAY = 0x30;
    public static final int SET_POINTER_VISIBLE = 0x31;
    public static final int PING = 0x32;
    public static final int BYE = 0x40;

    // ---- server -> Mac -------------------------------------------------
    public static final int DISPLAY_INFO = 0x80;
    public static final int ERROR = 0x81;
    public static final int PONG = 0x82;
    public static final int READY = 0x8F;

    private Framing() {
    }

    /** A decoded frame: its type byte and the raw payload that followed it. */
    public static final class Frame {
        public final int type;
        public final byte[] payload;

        public Frame(int type, byte[] payload) {
            this.type = type;
            this.payload = payload;
        }

        /** Big-endian reader positioned at the start of the payload. */
        public ByteBuffer reader() {
            return ByteBuffer.wrap(payload).order(ByteOrder.BIG_ENDIAN);
        }

        public String asUtf8() {
            return new String(payload, StandardCharsets.UTF_8);
        }

        @Override
        public String toString() {
            return "Frame(type=0x" + Integer.toHexString(type) + ", payload=" + payload.length + "B)";
        }
    }

    /** Encodes one complete frame, header included. */
    public static byte[] encode(int type, byte[] payload) {
        if (payload == null) {
            payload = new byte[0];
        }
        if (payload.length > MAX_PAYLOAD) {
            throw new IllegalArgumentException("payload too large: " + payload.length);
        }
        byte[] out = new byte[3 + payload.length];
        int length = 1 + payload.length;
        out[0] = (byte) ((length >>> 8) & 0xFF);
        out[1] = (byte) (length & 0xFF);
        out[2] = (byte) (type & 0xFF);
        System.arraycopy(payload, 0, out, 3, payload.length);
        return out;
    }

    /** Decodes exactly one frame from a complete wire buffer. Test helper. */
    public static Frame decode(byte[] wire) {
        if (wire.length < 3) {
            throw new IllegalArgumentException("short frame: " + wire.length);
        }
        int length = ((wire[0] & 0xFF) << 8) | (wire[1] & 0xFF);
        if (length < 1) {
            throw new IllegalArgumentException("length must count the type byte");
        }
        int payloadLength = length - 1;
        if (wire.length != 3 + payloadLength) {
            throw new IllegalArgumentException(
                    "declared " + payloadLength + " payload bytes, buffer holds " + (wire.length - 3));
        }
        byte[] payload = new byte[payloadLength];
        System.arraycopy(wire, 3, payload, 0, payloadLength);
        return new Frame(wire[2] & 0xFF, payload);
    }

    /**
     * Reads one frame, blocking until it is complete.
     *
     * @return the frame, or {@code null} if the peer closed cleanly on a frame boundary
     * @throws IOException on a truncated frame or a transport failure
     */
    public static Frame read(InputStream in) throws IOException {
        int hi = in.read();
        if (hi < 0) {
            return null;
        }
        int lo = in.read();
        if (lo < 0) {
            throw new IOException("truncated frame header");
        }
        int length = (hi << 8) | lo;
        if (length < 1) {
            throw new IOException("invalid frame length 0");
        }
        int type = in.read();
        if (type < 0) {
            throw new IOException("truncated frame type");
        }
        byte[] payload = new byte[length - 1];
        readFully(in, payload);
        return new Frame(type, payload);
    }

    /** Writes and flushes one frame. Callers must serialize concurrent writers. */
    public static void write(OutputStream out, int type, byte[] payload) throws IOException {
        out.write(encode(type, payload));
        out.flush();
    }

    private static void readFully(InputStream in, byte[] buf) throws IOException {
        int off = 0;
        while (off < buf.length) {
            int n = in.read(buf, off, buf.length - off);
            if (n < 0) {
                throw new IOException("truncated payload: wanted " + buf.length + ", got " + off);
            }
            off += n;
        }
    }

    // ---- payload builders ---------------------------------------------

    public static byte[] displayInfo(int widthPx, int heightPx, int rotation, float density) {
        ByteBuffer b = ByteBuffer.allocate(13).order(ByteOrder.BIG_ENDIAN);
        b.putInt(widthPx);
        b.putInt(heightPx);
        b.put((byte) (rotation & 0xFF));
        b.putFloat(density);
        return b.array();
    }

    public static byte[] pong(long echo) {
        return ByteBuffer.allocate(8).order(ByteOrder.BIG_ENDIAN).putLong(echo).array();
    }

    public static byte[] ready(int apiLevel, int flags) {
        return new byte[] { (byte) (apiLevel & 0xFF), (byte) (flags & 0xFF) };
    }

    public static byte[] error(String message) {
        byte[] raw = message.getBytes(StandardCharsets.UTF_8);
        if (raw.length <= MAX_PAYLOAD) {
            return raw;
        }
        byte[] clipped = new byte[MAX_PAYLOAD];
        System.arraycopy(raw, 0, clipped, 0, MAX_PAYLOAD);
        return clipped;
    }

    /**
     * Round-trips every frame shape the protocol defines. Shared by the desktop
     * unit test and by {@code Server --self-test} so the on-device dex can be
     * sanity checked without a Mac.
     *
     * @return a human readable report; throws {@link IllegalStateException} on failure
     */
    public static String selfTest() {
        StringBuilder log = new StringBuilder();

        // empty payload (GET_DISPLAY, BYE)
        Frame empty = decode(encode(GET_DISPLAY, new byte[0]));
        expect(empty.type == GET_DISPLAY, "GET_DISPLAY type");
        expect(empty.payload.length == 0, "GET_DISPLAY payload empty");
        expect(encode(GET_DISPLAY, new byte[0]).length == 3, "empty frame is 3 bytes");
        expect(encode(GET_DISPLAY, null)[1] == 1, "length counts the type byte");
        log.append("empty-payload ok\n");

        // DISPLAY_INFO
        Frame di = decode(encode(DISPLAY_INFO, displayInfo(1080, 2340, 3, 2.25f)));
        ByteBuffer r = di.reader();
        expect(di.type == DISPLAY_INFO, "DISPLAY_INFO type");
        expect(r.getInt() == 1080, "width");
        expect(r.getInt() == 2340, "height");
        expect((r.get() & 0xFF) == 3, "rotation");
        expect(r.getFloat() == 2.25f, "density");
        expect(di.payload.length == 13, "DISPLAY_INFO is 13 payload bytes");
        log.append("display-info ok\n");

        // PONG echoes a u64 unchanged, including the high bit
        long echo = 0xFEDCBA9876543210L;
        expect(decode(encode(PONG, pong(echo))).reader().getLong() == echo, "pong echo");
        log.append("pong ok\n");

        // READY
        Frame ready = decode(encode(READY, ready(37, 1)));
        expect((ready.payload[0] & 0xFF) == 37, "api level");
        expect((ready.payload[1] & 0xFF) == 1, "flags bit0");
        log.append("ready ok\n");

        // ERROR carries UTF-8, multi-byte included
        String msg = "injection failed — 한글";
        expect(msg.equals(decode(encode(ERROR, error(msg))).asUtf8()), "utf-8 error round-trip");
        log.append("error-utf8 ok\n");

        // streaming: several frames back to back through a pipe
        java.io.ByteArrayOutputStream sink = new java.io.ByteArrayOutputStream();
        try {
            write(sink, HELLO, new byte[] { 1 });
            write(sink, POINTER_MOVE, ByteBuffer.allocate(8).putFloat(12.5f).putFloat(-3.25f).array());
            write(sink, BYE, new byte[0]);
            java.io.ByteArrayInputStream src = new java.io.ByteArrayInputStream(sink.toByteArray());
            Frame f1 = read(src);
            expect(f1 != null && f1.type == HELLO && f1.payload[0] == 1, "streamed HELLO");
            Frame f2 = read(src);
            expect(f2 != null && f2.type == POINTER_MOVE, "streamed POINTER_MOVE type");
            ByteBuffer pm = f2.reader();
            expect(pm.getFloat() == 12.5f && pm.getFloat() == -3.25f, "streamed POINTER_MOVE coords");
            Frame f3 = read(src);
            expect(f3 != null && f3.type == BYE && f3.payload.length == 0, "streamed BYE");
            expect(read(src) == null, "clean EOF returns null");
        } catch (IOException e) {
            throw new IllegalStateException("stream round-trip threw", e);
        }
        log.append("stream ok\n");

        // a truncated payload must fail loudly rather than return a short frame
        byte[] truncated = new byte[] { 0x00, 0x05, (byte) TEXT, 'a' };
        try {
            read(new java.io.ByteArrayInputStream(truncated));
            throw new IllegalStateException("truncated payload should have thrown");
        } catch (IOException expected) {
            log.append("truncated-detected ok\n");
        }

        // maximum sized payload
        byte[] big = new byte[MAX_PAYLOAD];
        big[MAX_PAYLOAD - 1] = 0x7F;
        Frame bigFrame = decode(encode(TEXT, big));
        expect(bigFrame.payload.length == MAX_PAYLOAD, "max payload length");
        expect(bigFrame.payload[MAX_PAYLOAD - 1] == 0x7F, "max payload tail");
        try {
            encode(TEXT, new byte[MAX_PAYLOAD + 1]);
            throw new IllegalStateException("oversized payload should have thrown");
        } catch (IllegalArgumentException expected) {
            log.append("max-payload ok\n");
        }

        log.append("all framing checks passed");
        return log.toString();
    }

    private static void expect(boolean condition, String what) {
        if (!condition) {
            throw new IllegalStateException("framing self-test failed: " + what);
        }
    }
}
