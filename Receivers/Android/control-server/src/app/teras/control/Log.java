package app.teras.control;

import java.io.PrintWriter;
import java.io.StringWriter;

/** stderr logging with the prefix the Mac host greps for. */
public final class Log {

    private static final String PREFIX = "[teras-control] ";
    private static boolean verbose = false;

    private Log() {
    }

    public static void setVerbose(boolean on) {
        verbose = on;
    }

    public static void info(String message) {
        System.err.println(PREFIX + message);
        System.err.flush();
    }

    public static void warn(String message) {
        System.err.println(PREFIX + "WARN " + message);
        System.err.flush();
    }

    public static void error(String message, Throwable t) {
        System.err.println(PREFIX + "ERROR " + message + (t == null ? "" : ": " + describe(t)));
        if (t != null && verbose) {
            t.printStackTrace(System.err);
        }
        System.err.flush();
    }

    public static void debug(String message) {
        if (verbose) {
            System.err.println(PREFIX + "DEBUG " + message);
            System.err.flush();
        }
    }

    /** Unwraps reflective wrappers so the cause, not InvocationTargetException, is logged. */
    public static String describe(Throwable t) {
        Throwable cause = t;
        while (cause instanceof java.lang.reflect.InvocationTargetException && cause.getCause() != null) {
            cause = cause.getCause();
        }
        String message = cause.getMessage();
        return cause.getClass().getName() + (message == null ? "" : ": " + message);
    }

    public static String stackTrace(Throwable t) {
        StringWriter sw = new StringWriter();
        t.printStackTrace(new PrintWriter(sw));
        return sw.toString();
    }
}
