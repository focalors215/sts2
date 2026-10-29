package org.godotengine.godot;

import java.util.ArrayList;
import java.util.List;

/** Native-input consumer model: source is assigned only when managed code flushes. */
public final class GodotLib {
    public static final List<String> buffered = new ArrayList<>();
    public static final List<String> delivered = new ArrayList<>();
    public static int source;
    public static Thread lastDispatchThread;
    public static boolean shouldDispatchInputToRenderThread() { return false; }
    public static void flush() {
        for (String event : buffered) delivered.add(source + ":" + event);
        buffered.clear();
    }
    private static void input(String value) { lastDispatchThread = Thread.currentThread(); buffered.add(value); }
    public static void dispatchMouseEvent(int action, int buttons, float x, float y, float dx, float dy,
            boolean doubleTap, boolean relative, float pressure, float tiltX, float tiltY) { input("mouse/" + action + "/" + buttons); }
    public static void dispatchTouchEvent(int action, int pointer, int count, float[] positions, boolean doubleTap) { input("touch/" + action); }
    public static void key(int key, int unicode, int label, boolean pressed, boolean echo) { input("key/" + key + "/" + pressed); }
    public static void magnify(float x, float y, float factor) { input("magnify"); }
    public static void pan(float x, float y, float dx, float dy) { input("pan"); }
    public static void joybutton(int device, int button, boolean pressed) { input("joybutton"); }
    public static void joyaxis(int device, int axis, float value) { input("joyaxis"); }
    public static void joyhat(int device, int x, int y) { input("joyhat"); }
    public static void joyconnectionchanged(int device, boolean connected, String name) { input("joyconnection"); }
    public static void accelerometer(float x, float y, float z) { input("sensor"); }
    public static void gravity(float x, float y, float z) { input("sensor"); }
    public static void magnetometer(float x, float y, float z) { input("sensor"); }
    public static void gyroscope(float x, float y, float z) { input("sensor"); }
}
