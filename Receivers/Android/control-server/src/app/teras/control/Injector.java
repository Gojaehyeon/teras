package app.teras.control;

import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.MotionEvent;

import java.lang.reflect.Method;

/**
 * Injects mouse and keyboard events through the hidden
 * {@code InputManager#injectInputEvent(InputEvent, int)}.
 *
 * <p>The manager singleton moved in API 34: {@code InputManagerGlobal.getInstance()}
 * replaced {@code InputManager.getInstance()}. Both are probed, newest first.
 * Everything here is reflection over documented-by-observation framework
 * internals; no AOSP source is reproduced.
 */
public final class Injector {

    /** {@code InputManager.INJECT_INPUT_EVENT_MODE_ASYNC}. */
    public static final int MODE_ASYNC = 0;

    private final Object inputManager;
    private final Method injectInputEvent;
    private final Method setActionButton;
    private final KeyCharacterMap keyCharacterMap;
    private final String managerClassName;

    private int buttonState = 0;
    private long downTime = 0;
    private float lastX = 0;
    private float lastY = 0;
    private boolean pointerHovering = false;

    private int displayWidth = 1;
    private int displayHeight = 1;

    /**
     * Device id stamped on injected MotionEvents. 0 is the virtual device every
     * scrcpy-style injector uses. Overridable because some ROMs only draw the
     * system pointer for events attributed to a device that reports
     * SOURCE_MOUSE; see README.
     */
    private int pointerDeviceId = 0;

    public Injector() throws Exception {
        Object manager = null;
        Method inject = null;
        Throwable firstFailure = null;

        String[] candidates = {
                "android.hardware.input.InputManagerGlobal",
                "android.hardware.input.InputManager",
        };
        for (String className : candidates) {
            try {
                Class<?> type = Class.forName(className);
                Object instance = type.getMethod("getInstance").invoke(null);
                if (instance == null) {
                    throw new IllegalStateException(className + ".getInstance() returned null");
                }
                Method m = findInject(instance.getClass());
                if (m == null) {
                    throw new NoSuchMethodException(className + " has no injectInputEvent(InputEvent,int)");
                }
                manager = instance;
                inject = m;
                Log.info("input manager: " + className);
                break;
            } catch (Throwable t) {
                if (firstFailure == null) {
                    firstFailure = t;
                }
                Log.debug(className + " unusable: " + Log.describe(t));
            }
        }
        if (manager == null) {
            throw new IllegalStateException(
                    "no usable InputManager: " + (firstFailure == null ? "?" : Log.describe(firstFailure)));
        }
        this.inputManager = manager;
        this.injectInputEvent = inject;
        this.injectInputEvent.setAccessible(true);
        this.managerClassName = manager.getClass().getName();

        Method sab = null;
        try {
            sab = MotionEvent.class.getMethod("setActionButton", int.class);
            sab.setAccessible(true);
        } catch (Throwable t) {
            Log.warn("MotionEvent#setActionButton unavailable, "
                    + "ACTION_BUTTON_PRESS/RELEASE will be skipped: " + Log.describe(t));
        }
        this.setActionButton = sab;

        KeyCharacterMap kcm = null;
        try {
            kcm = KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD);
        } catch (Throwable t) {
            Log.warn("KeyCharacterMap unavailable, TEXT will fail: " + Log.describe(t));
        }
        this.keyCharacterMap = kcm;
    }

    public void setPointerDeviceId(int deviceId) {
        this.pointerDeviceId = deviceId;
    }

    public String managerClassName() {
        return managerClassName;
    }

    public boolean hasActionButton() {
        return setActionButton != null;
    }

    /** Coordinates from the Mac are clamped into these bounds (CONTROL.md section 6). */
    public void setDisplaySize(int width, int height) {
        this.displayWidth = Math.max(1, width);
        this.displayHeight = Math.max(1, height);
    }

    // ---- pointer -------------------------------------------------------

    /**
     * Absolute pointer move. Hovers while no button is held, drags otherwise.
     */
    public boolean pointerMove(float x, float y) {
        x = clampX(x);
        y = clampY(y);
        lastX = x;
        lastY = y;
        if (buttonState != 0) {
            return motion(MotionEvent.ACTION_MOVE, x, y, buttonState, 0);
        }
        pointerHovering = true;
        return motion(MotionEvent.ACTION_HOVER_MOVE, x, y, 0, 0);
    }

    /**
     * Press or release a mouse button at an absolute position.
     *
     * @param button 0 left, 1 right, 2 middle (CONTROL.md message 0x11)
     */
    public boolean button(int button, boolean down, float x, float y) {
        int mask = buttonMask(button);
        if (mask == 0) {
            throw new IllegalArgumentException("unknown button " + button);
        }
        x = clampX(x);
        y = clampY(y);
        lastX = x;
        lastY = y;
        long now = SystemClock.uptimeMillis();
        boolean ok;
        if (down) {
            boolean first = buttonState == 0;
            if (first) {
                downTime = now;
                pointerHovering = false;
            }
            buttonState |= mask;
            ok = motion(first ? MotionEvent.ACTION_DOWN : MotionEvent.ACTION_MOVE,
                    x, y, buttonState, 0);
            ok &= motion(MotionEvent.ACTION_BUTTON_PRESS, x, y, buttonState, mask);
        } else {
            buttonState &= ~mask;
            ok = motion(MotionEvent.ACTION_BUTTON_RELEASE, x, y, buttonState, mask);
            ok &= motion(buttonState == 0 ? MotionEvent.ACTION_UP : MotionEvent.ACTION_MOVE,
                    x, y, buttonState, 0);
        }
        return ok;
    }

    /**
     * Wheel notches. Positive {@code vDelta} scrolls content up, matching
     * Android's AXIS_VSCROLL sign convention.
     */
    public boolean scroll(float x, float y, float hDelta, float vDelta) {
        x = clampX(x);
        y = clampY(y);
        lastX = x;
        lastY = y;
        MotionEvent.PointerProperties[] properties = pointerProperties();
        MotionEvent.PointerCoords[] coords = pointerCoords(x, y);
        coords[0].setAxisValue(MotionEvent.AXIS_VSCROLL, vDelta);
        coords[0].setAxisValue(MotionEvent.AXIS_HSCROLL, hDelta);
        long now = SystemClock.uptimeMillis();
        MotionEvent event = MotionEvent.obtain(
                downTime == 0 ? now : downTime, now, MotionEvent.ACTION_SCROLL,
                1, properties, coords,
                0, buttonState, 1f, 1f, pointerDeviceId, 0,
                InputDevice.SOURCE_MOUSE, 0);
        return inject(event);
    }

    /**
     * Hides or shows the system pointer by faking the mouse leaving the screen.
     * The off-screen hover is deliberately not clamped.
     */
    public boolean setPointerVisible(boolean visible) {
        long now = SystemClock.uptimeMillis();
        if (visible) {
            pointerHovering = true;
            return motion(MotionEvent.ACTION_HOVER_ENTER, lastX, lastY, 0, 0)
                    & motion(MotionEvent.ACTION_HOVER_MOVE, lastX, lastY, 0, 0);
        }
        boolean ok = true;
        if (pointerHovering) {
            ok = motion(MotionEvent.ACTION_HOVER_EXIT, lastX, lastY, 0, 0);
            pointerHovering = false;
        }
        MotionEvent.PointerProperties[] properties = pointerProperties();
        MotionEvent.PointerCoords[] coords = pointerCoords(-1f, -1f);
        MotionEvent event = MotionEvent.obtain(
                now, now, MotionEvent.ACTION_HOVER_MOVE, 1, properties, coords,
                0, 0, 1f, 1f, pointerDeviceId, 0, InputDevice.SOURCE_MOUSE, 0);
        return inject(event) & ok;
    }

    // ---- keyboard ------------------------------------------------------

    public boolean key(boolean down, int keyCode, int metaState, int repeat) {
        long now = SystemClock.uptimeMillis();
        KeyEvent event = new KeyEvent(
                now, now,
                down ? KeyEvent.ACTION_DOWN : KeyEvent.ACTION_UP,
                keyCode, repeat, metaState,
                KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0,
                InputDevice.SOURCE_KEYBOARD);
        return inject(event);
    }

    /**
     * Types a string through the virtual keyboard character map.
     *
     * @return the number of characters that could not be mapped to key events
     */
    public int text(String text) {
        if (keyCharacterMap == null) {
            throw new IllegalStateException("KeyCharacterMap unavailable on this device");
        }
        int unmapped = 0;
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            KeyEvent[] events = keyCharacterMap.getEvents(new char[] { c });
            if (events == null || events.length == 0) {
                unmapped++;
                Log.warn("no key events for U+" + String.format("%04X", (int) c) + ", skipped");
                continue;
            }
            for (KeyEvent source : events) {
                // Rebuild so device id and source are certainly the virtual keyboard.
                KeyEvent event = new KeyEvent(
                        source.getDownTime(), source.getEventTime(), source.getAction(),
                        source.getKeyCode(), source.getRepeatCount(), source.getMetaState(),
                        KeyCharacterMap.VIRTUAL_KEYBOARD, source.getScanCode(),
                        source.getFlags(), InputDevice.SOURCE_KEYBOARD);
                if (!inject(event)) {
                    throw new IllegalStateException(
                            "injectInputEvent refused key " + source.getKeyCode());
                }
            }
        }
        return unmapped;
    }

    // ---- plumbing ------------------------------------------------------

    /** Injects a hover move at the last known position to test whether injection works. */
    public boolean probe() {
        return motion(MotionEvent.ACTION_HOVER_MOVE, clampX(lastX), clampY(lastY), 0, 0);
    }

    private boolean motion(int action, float x, float y, int buttons, int actionButton) {
        long now = SystemClock.uptimeMillis();
        long down = (action == MotionEvent.ACTION_DOWN || downTime == 0) ? now : downTime;
        MotionEvent event = MotionEvent.obtain(
                down, now, action, 1,
                pointerProperties(), pointerCoords(x, y),
                0, buttons, 1f, 1f, pointerDeviceId, 0,
                InputDevice.SOURCE_MOUSE, 0);
        if (actionButton != 0) {
            if (setActionButton == null) {
                event.recycle();
                return true; // press/release pair is optional; DOWN/UP alone still clicks
            }
            try {
                setActionButton.invoke(event, actionButton);
            } catch (Throwable t) {
                Log.debug("setActionButton failed: " + Log.describe(t));
                event.recycle();
                return true;
            }
        }
        return inject(event);
    }

    private static MotionEvent.PointerProperties[] pointerProperties() {
        MotionEvent.PointerProperties properties = new MotionEvent.PointerProperties();
        properties.id = 0;
        properties.toolType = MotionEvent.TOOL_TYPE_MOUSE;
        return new MotionEvent.PointerProperties[] { properties };
    }

    private static MotionEvent.PointerCoords[] pointerCoords(float x, float y) {
        MotionEvent.PointerCoords coords = new MotionEvent.PointerCoords();
        coords.x = x;
        coords.y = y;
        coords.pressure = 1f;
        coords.size = 1f;
        return new MotionEvent.PointerCoords[] { coords };
    }

    private boolean inject(InputEvent event) {
        try {
            Object result = injectInputEvent.invoke(inputManager, event, MODE_ASYNC);
            return !(result instanceof Boolean) || (Boolean) result;
        } catch (Throwable t) {
            throw new RuntimeException("injectInputEvent threw: " + Log.describe(t), t);
        } finally {
            if (event instanceof MotionEvent) {
                ((MotionEvent) event).recycle();
            }
        }
    }

    private static Method findInject(Class<?> type) {
        for (Class<?> c = type; c != null; c = c.getSuperclass()) {
            for (Method m : c.getDeclaredMethods()) {
                if (!"injectInputEvent".equals(m.getName())) {
                    continue;
                }
                Class<?>[] params = m.getParameterTypes();
                if (params.length == 2 && params[0].isAssignableFrom(MotionEvent.class)
                        && params[1] == int.class) {
                    return m;
                }
            }
        }
        return null;
    }

    private static int buttonMask(int button) {
        switch (button) {
            case 0:
                return MotionEvent.BUTTON_PRIMARY;
            case 1:
                return MotionEvent.BUTTON_SECONDARY;
            case 2:
                return MotionEvent.BUTTON_TERTIARY;
            default:
                return 0;
        }
    }

    private float clampX(float x) {
        return Math.max(0f, Math.min(x, displayWidth - 1f));
    }

    private float clampY(float y) {
        return Math.max(0f, Math.min(y, displayHeight - 1f));
    }
}
