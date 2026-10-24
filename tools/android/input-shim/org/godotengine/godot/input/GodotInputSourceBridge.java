package org.godotengine.godot.input;

import android.view.InputDevice;
import android.view.KeyEvent;
import android.view.MotionEvent;

import org.godotengine.godot.Godot;
import org.godotengine.godot.variant.Callable;

/** Carries event provenance alongside Godot's original pooled input dispatch. */
public final class GodotInputSourceBridge {
    public static final int UNKNOWN = 0;
    public static final int TOUCH = 1;
    public static final int HARDWARE_MOUSE = 2;
    public static final int HARDWARE_KEYBOARD = 3;
    public static final int VIRTUAL = 4;

    static final int RUN = 0;
    static final int REQUEUED = 1;
    static final int DISCARD = 2;
    static final int UNTRACKED = -1;
    private static final Object[][] SIGNAL_ARGUMENTS = {
        {"android_input_source", UNKNOWN},
        {"android_input_source", TOUCH},
        {"android_input_source", HARDWARE_MOUSE},
        {"android_input_source", HARDWARE_KEYBOARD},
        {"android_input_source", VIRTUAL}
    };
    private static final ThreadLocal<SourceScope> SOURCE = new ThreadLocal<SourceScope>() {
        @Override protected SourceScope initialValue() { return new SourceScope(); }
    };
    private static volatile Binding binding;
    private static long nextEpoch;

    private GodotInputSourceBridge() {}

    private static final class SourceScope {
        int source = UNTRACKED;
    }

    private static final class Binding implements Runnable {
        final Godot godot;
        final long objectId;
        final long epoch;
        final boolean active;
        volatile Thread renderThread;
        private int lastSource = UNTRACKED;

        Binding(Godot godot, long objectId, long epoch, boolean active, Thread renderThread) {
            this.godot = godot;
            this.objectId = objectId;
            this.epoch = epoch;
            this.active = active;
            this.renderThread = renderThread;
        }

        @Override public void run() {
            if (binding != this || !active) return;
            renderThread = Thread.currentThread();
            emit(UNKNOWN);
        }

        void emit(int source) {
            if (source == lastSource) return;
            // Synchronous: the managed receiver flushes buffered native input under
            // the preceding source before it installs this boundary's source.
            Callable.call(objectId, "emit_signal", SIGNAL_ARGUMENTS[source]);
            lastSource = source;
        }
    }

    /** Called by the singleton on Godot's main/render thread after signal connection. */
    public static synchronized void bind(Godot godot, long objectId, boolean active) {
        if (objectId == 0) throw new IllegalArgumentException("input-source sink must be a Godot object");
        Binding next = new Binding(godot, objectId, ++nextEpoch, active, Thread.currentThread());
        binding = next;
        next.run();
    }

    /** Lifecycle transitions invalidate captured events, including already queued runnables. */
    public static synchronized void setActive(Godot godot, boolean active) {
        Binding previous = binding;
        if (previous == null || previous.godot != godot || previous.active == active) return;
        Binding next = new Binding(godot, previous.objectId, ++nextEpoch, active, previous.renderThread);
        binding = next;
        if (active) godot.runOnRenderThread(next);
    }

    public static synchronized void unbind(Godot godot) {
        if (binding != null && binding.godot == godot) {
            binding = null;
            ++nextEpoch;
        }
    }

    static int pushSource(int source) {
        SourceScope scope = SOURCE.get();
        int previous = scope.source;
        scope.source = source;
        return previous;
    }

    static int pushMotionSource(MotionEvent event) {
        SourceScope scope = SOURCE.get();
        int previous = scope.source;
        if (previous == UNTRACKED) scope.source = motionSource(event);
        return previous;
    }

    static void popSource(int previous) {
        SOURCE.get().source = previous;
    }

    static int motionSource(MotionEvent event) {
        if (event.isFromSource(InputDevice.SOURCE_MOUSE)
                || event.isFromSource(InputDevice.SOURCE_MOUSE_RELATIVE)
                || event.isFromSource(InputDevice.SOURCE_TOUCHPAD)) {
            InputDevice device = event.getDevice();
            return event.getDeviceId() < 0 || device == null || device.isVirtual() ? VIRTUAL : HARDWARE_MOUSE;
        }
        int tool = event.getPointerCount() == 0 ? MotionEvent.TOOL_TYPE_UNKNOWN : event.getToolType(0);
        if (tool == MotionEvent.TOOL_TYPE_FINGER || tool == MotionEvent.TOOL_TYPE_STYLUS
                || tool == MotionEvent.TOOL_TYPE_ERASER || event.isFromSource(InputDevice.SOURCE_TOUCHSCREEN)
                || event.isFromSource(InputDevice.SOURCE_STYLUS)) return TOUCH;
        return UNKNOWN;
    }

    static int keySource(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_BACK || keyCode == KeyEvent.KEYCODE_VOLUME_UP
                || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN || keyCode == KeyEvent.KEYCODE_VOLUME_MUTE
                || KeyEvent.isGamepadButton(keyCode)
                || (event.getFlags() & (KeyEvent.FLAG_SOFT_KEYBOARD | KeyEvent.FLAG_VIRTUAL_HARD_KEY)) != 0
                || event.getDeviceId() < 0 || !event.isFromSource(InputDevice.SOURCE_KEYBOARD)
                || event.isFromSource(InputDevice.SOURCE_GAMEPAD)
                || event.isFromSource(InputDevice.SOURCE_JOYSTICK)) return VIRTUAL;
        // Real keyboards may also advertise DPAD. A stand-alone DPAD is not a keyboard.
        InputDevice device = event.getDevice();
        return device == null || device.isVirtual() || device.supportsSource(InputDevice.SOURCE_GAMEPAD)
                || device.supportsSource(InputDevice.SOURCE_JOYSTICK) ? VIRTUAL : HARDWARE_KEYBOARD;
    }

    static void capture(InputEventRunnable event) {
        int source = SOURCE.get().source;
        event.sts2InputSource = source == UNTRACKED ? UNKNOWN : source;
        Binding current = binding;
        event.sts2InputEpoch = current == null ? 0 : current.epoch;
    }

    /** The return code keeps requeued objects out of the pool until their real run. */
    static int beforeRun(InputEventRunnable event, int source) {
        if (source == UNTRACKED) return RUN;
        Binding current = binding;
        // Fresh unbound events retain the engine pipeline; detached-session queues do not.
        if (current == null) return event.sts2InputEpoch == 0 ? RUN : DISCARD;
        if (!current.active || event.sts2InputEpoch != current.epoch) return DISCARD;
        if (Thread.currentThread() != current.renderThread) {
            current.godot.runOnRenderThread(event);
            return REQUEUED;
        }
        current.emit(source);
        // A synchronous flush can re-enter scene lifecycle/binding code.
        return binding == current ? RUN : DISCARD;
    }
}
