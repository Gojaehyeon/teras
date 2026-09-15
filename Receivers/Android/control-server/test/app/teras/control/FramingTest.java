package app.teras.control;

/**
 * Desktop JVM test for {@link Framing}. No Android runtime, no JUnit jar:
 * {@code build.sh} compiles this against the plain JDK and runs it, so a
 * framing regression fails the build before anything is dexed.
 */
public final class FramingTest {

    public static void main(String[] args) {
        try {
            System.out.println(Framing.selfTest());
        } catch (Throwable t) {
            System.err.println("FramingTest FAILED");
            t.printStackTrace(System.err);
            System.exit(1);
        }
        System.out.println("FramingTest PASSED");
    }
}
