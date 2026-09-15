package app.teras.control;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Reads the logical geometry of display 0 through the hidden
 * {@code DisplayManagerGlobal#getDisplayInfo(int)}, falling back to parsing
 * {@code wm size} / {@code wm density} / {@code dumpsys display} when the
 * hidden API is unavailable or blocked.
 */
public final class DisplayInfoReader {

    public static final class Info {
        public final int width;
        public final int height;
        public final int rotation;
        public final int densityDpi;
        /** How the values were obtained, for the READY log line. */
        public final String source;

        Info(int width, int height, int rotation, int densityDpi, String source) {
            this.width = width;
            this.height = height;
            this.rotation = rotation;
            this.densityDpi = densityDpi;
            this.source = source;
        }

        /**
         * Android's {@code DisplayMetrics.density}: the dp-to-px scale factor,
         * i.e. {@code densityDpi / 160}. CONTROL.md calls this field "density".
         */
        public float density() {
            return densityDpi / 160.0f;
        }

        public boolean sameGeometry(Info other) {
            return other != null
                    && width == other.width
                    && height == other.height
                    && rotation == other.rotation
                    && densityDpi == other.densityDpi;
        }

        @Override
        public String toString() {
            return width + "x" + height + " rot=" + rotation + " dpi=" + densityDpi
                    + " density=" + density() + " via " + source;
        }
    }

    private static final Pattern SIZE = Pattern.compile("(\\d+)x(\\d+)");
    private static final Pattern DENSITY = Pattern.compile("density:\\s*(\\d+)");
    private static final Pattern ROTATION = Pattern.compile(
            "(?:mCurrentRotation|SurfaceOrientation|mRotation|rotation)[=:]\\s*(\\d)");

    private Object displayManagerGlobal;
    private Method getDisplayInfo;
    private boolean reflectionBroken;

    /** Reads the current geometry, or {@code null} if every strategy failed. */
    public Info read() {
        if (!reflectionBroken) {
            Info viaReflection = readViaReflection();
            if (viaReflection != null) {
                return viaReflection;
            }
        }
        return readViaShell();
    }

    private Info readViaReflection() {
        try {
            if (displayManagerGlobal == null) {
                Class<?> global = Class.forName("android.hardware.display.DisplayManagerGlobal");
                displayManagerGlobal = global.getMethod("getInstance").invoke(null);
                if (displayManagerGlobal == null) {
                    throw new IllegalStateException("DisplayManagerGlobal.getInstance() returned null");
                }
                getDisplayInfo = global.getMethod("getDisplayInfo", int.class);
            }
            Object info = getDisplayInfo.invoke(displayManagerGlobal, 0);
            if (info == null) {
                throw new IllegalStateException("getDisplayInfo(0) returned null");
            }
            Class<?> type = info.getClass();
            int width = type.getField("logicalWidth").getInt(info);
            int height = type.getField("logicalHeight").getInt(info);
            int rotation = type.getField("rotation").getInt(info);
            int dpi = type.getField("logicalDensityDpi").getInt(info);
            if (width <= 0 || height <= 0) {
                throw new IllegalStateException("implausible size " + width + "x" + height);
            }
            return new Info(width, height, rotation, dpi, "DisplayManagerGlobal");
        } catch (Throwable t) {
            if (!reflectionBroken) {
                reflectionBroken = true;
                Log.warn("DisplayManagerGlobal unusable, falling back to shell: " + Log.describe(t));
            }
            return null;
        }
    }

    private Info readViaShell() {
        try {
            String sizeOut = run("wm", "size");
            String densityOut = run("wm", "density");
            int[] size = parseSize(sizeOut);
            if (size == null) {
                Log.warn("could not parse `wm size` output: " + sizeOut.trim());
                return null;
            }
            int dpi = parseLast(DENSITY, densityOut, 160);
            int rotation = parseRotation();
            int width = size[0];
            int height = size[1];
            // `wm size` reports the natural orientation; swap for landscape.
            if (rotation == 1 || rotation == 3) {
                int swap = width;
                width = height;
                height = swap;
            }
            return new Info(width, height, rotation, dpi, "wm/dumpsys");
        } catch (Throwable t) {
            Log.warn("shell display probe failed: " + Log.describe(t));
            return null;
        }
    }

    private int parseRotation() {
        try {
            String dump = run("dumpsys", "display");
            Matcher m = ROTATION.matcher(dump);
            if (m.find()) {
                return Integer.parseInt(m.group(1));
            }
        } catch (Throwable ignored) {
            // fall through
        }
        try {
            String dump = run("dumpsys", "input");
            Matcher m = ROTATION.matcher(dump);
            if (m.find()) {
                return Integer.parseInt(m.group(1));
            }
        } catch (Throwable ignored) {
            // fall through
        }
        return 0;
    }

    /** Prefers an "Override size:" line over the physical one, like `wm size` prints it. */
    private static int[] parseSize(String out) {
        int[] found = null;
        for (String line : out.split("\n")) {
            Matcher m = SIZE.matcher(line);
            if (!m.find()) {
                continue;
            }
            int[] candidate = new int[] { Integer.parseInt(m.group(1)), Integer.parseInt(m.group(2)) };
            if (found == null || line.toLowerCase().contains("override")) {
                found = candidate;
            }
        }
        return found;
    }

    private static int parseLast(Pattern pattern, String out, int fallback) {
        int value = fallback;
        Matcher m = pattern.matcher(out);
        while (m.find()) {
            value = Integer.parseInt(m.group(1));
        }
        return value;
    }

    private static String run(String... command) throws Exception {
        ProcessBuilder pb = new ProcessBuilder(command);
        pb.redirectErrorStream(true);
        Process p = pb.start();
        StringBuilder sb = new StringBuilder();
        BufferedReader reader = new BufferedReader(
                new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8));
        try {
            String line;
            while ((line = reader.readLine()) != null) {
                sb.append(line).append('\n');
            }
        } finally {
            reader.close();
        }
        p.waitFor();
        return sb.toString();
    }
}
