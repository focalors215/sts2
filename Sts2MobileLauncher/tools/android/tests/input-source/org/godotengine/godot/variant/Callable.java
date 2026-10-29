package org.godotengine.godot.variant;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.godotengine.godot.GodotLib;

public final class Callable {
    public static final List<Integer> boundaries = new ArrayList<>();
    private static final Map<Integer, Object[]> arguments = new HashMap<>();
    public static Thread renderThread;
    public static Runnable duringBoundary;
    public static Object call(long objectId, String method, Object... values) {
        if (objectId != 77 || !method.equals("emit_signal") || !values[0].equals("android_input_source")) throw new AssertionError("source ABI");
        if (Thread.currentThread() != renderThread) throw new AssertionError("source signal is not synchronous on render thread");
        int source = (Integer) values[1];
        Object[] previous = arguments.putIfAbsent(source, values);
        if (previous != null && previous != values) throw new AssertionError("source arguments were allocated per boundary");
        GodotLib.flush();
        GodotLib.source = source;
        boundaries.add(source);
        Runnable callback = duringBoundary;
        duringBoundary = null;
        if (callback != null) callback.run();
        return null;
    }
}
