package app.teras.control;

import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.Build;
import android.os.Looper;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.ByteBuffer;

/**
 * Teras Control server (docs/CONTROL.md protocol v1).
 *
 * <p>Not an Android app: a plain Java main class dexed into
 * {@code /data/local/tmp/teras-control.jar} and started as the {@code shell}
 * UID with
 * {@code app_process / app.teras.control.Server <token>}.
 */
public final class Server {

    private static final String SOCKET_PREFIX = "teras_control_";
    private static final long DISPLAY_POLL_MS = 500;
    /** CONTROL.md section 2: exit when the client has been gone this long. */
    private static final long IDLE_EXIT_MS = 5000;

    private final String socketName;
    private final int pointerDeviceId;
    private final DisplayInfoReader displayReader = new DisplayInfoReader();

    private volatile LocalServerSocket serverSocket;
    private volatile Connection connection;
    private volatile DisplayInfoReader.Info lastInfo;
    private volatile long lastDisconnectAt = 0;
    private volatile boolean running = true;

    private Injector injector;

    private Server(String token, int pointerDeviceId) {
        this.socketName = SOCKET_PREFIX + token;
        this.pointerDeviceId = pointerDeviceId;
    }

    public static void main(String[] args) {
        if (args.length > 0 && "--self-test".equals(args[0])) {
            try {
                Log.info(Framing.selfTest());
                System.exit(0);
            } catch (Throwable t) {
                Log.error("self-test failed", t);
                System.err.println(Log.stackTrace(t));
                System.exit(1);
            }
            return;
        }
        if (args.length < 1 || args[0].isEmpty()) {
            Log.error("usage: app_process / app.teras.control.Server <token> [--verbose]", null);
            System.exit(2);
            return;
        }
        int pointerDeviceId = 0;
        for (int i = 0; i < args.length; i++) {
            if ("--verbose".equals(args[i])) {
                Log.setVerbose(true);
            } else if ("--device-id".equals(args[i]) && i + 1 < args.length) {
                pointerDeviceId = Integer.parseInt(args[++i]);
            }
        }
        prepareLooper();
        new Server(args[0], pointerDeviceId).run();
    }

    /** Some framework internals expect a prepared looper on the calling thread. */
    @SuppressWarnings("deprecation")
    private static void prepareLooper() {
        try {
            if (Looper.myLooper() == null) {
                Looper.prepareMainLooper();
            }
        } catch (Throwable t) {
            Log.debug("Looper.prepareMainLooper skipped: " + Log.describe(t));
        }
    }

    private void run() {
        Log.info("starting, api=" + Build.VERSION.SDK_INT
                + " device=" + Build.MODEL + " socket=" + socketName);

        try {
            injector = new Injector();
            injector.setPointerDeviceId(pointerDeviceId);
        } catch (Throwable t) {
            Log.error("input injection unavailable", t);
            injector = null;
        }

        lastInfo = displayReader.read();
        if (lastInfo != null) {
            Log.info("display: " + lastInfo);
            if (injector != null) {
                injector.setDisplaySize(lastInfo.width, lastInfo.height);
            }
        } else {
            Log.warn("display geometry unknown at startup");
        }

        try {
            serverSocket = new LocalServerSocket(socketName);
        } catch (IOException e) {
            Log.error("cannot bind localabstract:" + socketName, e);
            System.exit(3);
            return;
        }
        Log.info("listening on localabstract:" + socketName);

        Runtime.getRuntime().addShutdownHook(new Thread(new Runnable() {
            @Override
            public void run() {
                Log.info("shutting down");
                running = false;
                closeQuietly(serverSocket);
                Connection c = connection;
                if (c != null) {
                    c.close();
                }
            }
        }, "teras-shutdown"));

        startDisplayPoller();
        startIdleWatchdog();

        while (running) {
            LocalSocket client;
            try {
                client = serverSocket.accept();
            } catch (IOException e) {
                if (running) {
                    Log.error("accept failed", e);
                }
                break;
            }
            Connection previous = connection;
            if (previous != null) {
                Log.info("replacing existing client");
                previous.close();
            }
            Connection current = new Connection(client);
            connection = current;
            lastDisconnectAt = 0;
            Log.info("client connected");
            Thread handler = new Thread(new Runnable() {
                @Override
                public void run() {
                    serve(current);
                }
            }, "teras-client");
            handler.setDaemon(true);
            handler.start();
        }
        Log.info("accept loop ended");
    }

    // ---- per-connection -------------------------------------------------

    private void serve(Connection c) {
        try {
            InputStream in = c.socket.getInputStream();
            while (running && !c.closed) {
                Framing.Frame frame;
                try {
                    frame = Framing.read(in);
                } catch (IOException e) {
                    Log.info("read ended: " + Log.describe(e));
                    break;
                }
                if (frame == null) {
                    Log.info("client closed the stream");
                    break;
                }
                if (frame.type == Framing.BYE) {
                    Log.info("BYE");
                    break;
                }
                try {
                    handle(c, frame);
                } catch (Throwable t) {
                    String message = Log.describe(t);
                    Log.warn("handling 0x" + Integer.toHexString(frame.type) + " failed: " + message);
                    Log.debug(Log.stackTrace(t));
                    c.sendQuietly(Framing.ERROR, Framing.error(message));
                }
            }
        } catch (Throwable t) {
            Log.error("connection failed", t);
        } finally {
            c.close();
            if (connection == c) {
                connection = null;
                lastDisconnectAt = System.currentTimeMillis();
                Log.info("client disconnected, exiting in " + IDLE_EXIT_MS + " ms unless it returns");
            }
        }
    }

    private void handle(Connection c, Framing.Frame frame) throws IOException {
        ByteBuffer p = frame.reader();
        switch (frame.type) {
            case Framing.HELLO: {
                int version = p.remaining() > 0 ? (p.get() & 0xFF) : 0;
                Log.info("HELLO version=" + version);
                if (version != 1) {
                    c.send(Framing.ERROR, Framing.error("unsupported protocol version " + version));
                }
                sendDisplayInfo(c, refreshDisplay());
                sendReady(c);
                break;
            }
            case Framing.POINTER_MOVE: {
                require(p, 8, "POINTER_MOVE");
                injector().pointerMove(p.getFloat(), p.getFloat());
                break;
            }
            case Framing.BUTTON: {
                require(p, 10, "BUTTON");
                int button = p.get() & 0xFF;
                boolean down = (p.get() & 0xFF) != 0;
                float x = p.getFloat();
                float y = p.getFloat();
                injector().button(button, down, x, y);
                break;
            }
            case Framing.SCROLL: {
                require(p, 16, "SCROLL");
                float x = p.getFloat();
                float y = p.getFloat();
                float h = p.getFloat();
                float v = p.getFloat();
                injector().scroll(x, y, h, v);
                break;
            }
            case Framing.KEY: {
                require(p, 13, "KEY");
                boolean down = (p.get() & 0xFF) != 0;
                int keyCode = p.getInt();
                int metaState = p.getInt();
                int repeat = p.getInt();
                injector().key(down, keyCode, metaState, repeat);
                break;
            }
            case Framing.TEXT: {
                String text = frame.asUtf8();
                int unmapped = injector().text(text);
                if (unmapped > 0) {
                    c.send(Framing.ERROR,
                            Framing.error(unmapped + " character(s) had no virtual-keyboard mapping"));
                }
                break;
            }
            case Framing.GET_DISPLAY: {
                sendDisplayInfo(c, refreshDisplay());
                break;
            }
            case Framing.SET_POINTER_VISIBLE: {
                require(p, 1, "SET_POINTER_VISIBLE");
                injector().setPointerVisible((p.get() & 0xFF) != 0);
                break;
            }
            case Framing.PING: {
                require(p, 8, "PING");
                c.send(Framing.PONG, Framing.pong(p.getLong()));
                break;
            }
            default:
                Log.warn("unknown message type 0x" + Integer.toHexString(frame.type));
                c.send(Framing.ERROR, Framing.error("unknown message type 0x"
                        + Integer.toHexString(frame.type)));
        }
    }

    private void sendReady(Connection c) throws IOException {
        int flags = 0;
        if (injector != null) {
            try {
                if (injector.probe()) {
                    flags |= 0x01;
                } else {
                    Log.warn("probe injection returned false");
                }
            } catch (Throwable t) {
                Log.error("probe injection threw", t);
            }
        }
        int api = Math.min(Build.VERSION.SDK_INT, 255);
        Log.info("READY api=" + api + " flags=" + flags
                + (injector == null ? "" : " manager=" + injector.managerClassName()
                        + " actionButton=" + injector.hasActionButton()));
        c.send(Framing.READY, Framing.ready(api, flags));
        if (flags == 0) {
            c.send(Framing.ERROR, Framing.error("input injection is not working on this device"));
        }
    }

    private Injector injector() {
        if (injector == null) {
            throw new IllegalStateException("input injection unavailable on this device");
        }
        return injector;
    }

    private static void require(ByteBuffer p, int bytes, String what) {
        if (p.remaining() < bytes) {
            throw new IllegalArgumentException(
                    what + " needs " + bytes + " payload bytes, got " + p.remaining());
        }
    }

    // ---- display --------------------------------------------------------

    private DisplayInfoReader.Info refreshDisplay() {
        DisplayInfoReader.Info info = displayReader.read();
        if (info != null) {
            lastInfo = info;
            if (injector != null) {
                injector.setDisplaySize(info.width, info.height);
            }
        }
        return lastInfo;
    }

    private void sendDisplayInfo(Connection c, DisplayInfoReader.Info info) throws IOException {
        if (info == null) {
            c.send(Framing.ERROR, Framing.error("display geometry unavailable"));
            return;
        }
        c.send(Framing.DISPLAY_INFO,
                Framing.displayInfo(info.width, info.height, info.rotation, info.density()));
    }

    private void startDisplayPoller() {
        Thread poller = new Thread(new Runnable() {
            @Override
            public void run() {
                while (running) {
                    try {
                        Thread.sleep(DISPLAY_POLL_MS);
                    } catch (InterruptedException e) {
                        return;
                    }
                    DisplayInfoReader.Info info;
                    try {
                        info = displayReader.read();
                    } catch (Throwable t) {
                        Log.debug("display poll failed: " + Log.describe(t));
                        continue;
                    }
                    if (info == null || info.sameGeometry(lastInfo)) {
                        continue;
                    }
                    lastInfo = info;
                    if (injector != null) {
                        injector.setDisplaySize(info.width, info.height);
                    }
                    Log.info("display changed: " + info);
                    Connection c = connection;
                    if (c != null) {
                        c.sendQuietly(Framing.DISPLAY_INFO,
                                Framing.displayInfo(info.width, info.height, info.rotation, info.density()));
                    }
                }
            }
        }, "teras-display-poll");
        poller.setDaemon(true);
        poller.start();
    }

    private void startIdleWatchdog() {
        Thread watchdog = new Thread(new Runnable() {
            @Override
            public void run() {
                while (running) {
                    try {
                        Thread.sleep(250);
                    } catch (InterruptedException e) {
                        return;
                    }
                    long since = lastDisconnectAt;
                    if (connection == null && since != 0
                            && System.currentTimeMillis() - since >= IDLE_EXIT_MS) {
                        Log.info("no client for " + IDLE_EXIT_MS + " ms, exiting");
                        running = false;
                        closeQuietly(serverSocket);
                        System.exit(0);
                    }
                }
            }
        }, "teras-idle");
        watchdog.setDaemon(true);
        watchdog.start();
    }

    // ---- connection -----------------------------------------------------

    private static final class Connection {
        final LocalSocket socket;
        private final Object writeLock = new Object();
        private OutputStream out;
        volatile boolean closed;

        Connection(LocalSocket socket) {
            this.socket = socket;
        }

        void send(int type, byte[] payload) throws IOException {
            synchronized (writeLock) {
                if (closed) {
                    throw new IOException("connection closed");
                }
                if (out == null) {
                    out = socket.getOutputStream();
                }
                Framing.write(out, type, payload);
            }
        }

        void sendQuietly(int type, byte[] payload) {
            try {
                send(type, payload);
            } catch (IOException e) {
                Log.debug("send 0x" + Integer.toHexString(type) + " failed: " + Log.describe(e));
            }
        }

        void close() {
            closed = true;
            try {
                socket.close();
            } catch (IOException ignored) {
                // already gone
            }
        }
    }

    private static void closeQuietly(LocalServerSocket socket) {
        if (socket == null) {
            return;
        }
        try {
            socket.close();
        } catch (IOException ignored) {
            // already gone
        }
    }
}
