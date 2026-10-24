package org.godotengine.godot.input;

import android.view.InputDevice;
import android.view.KeyEvent;
import android.view.MotionEvent;
import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Set;
import java.util.concurrent.atomic.AtomicReference;
import org.godotengine.godot.Godot;
import org.godotengine.godot.GodotLib;
import org.godotengine.godot.variant.Callable;
import sun.misc.Unsafe;

/** Executes the AAR's actual instrumented runnable and its original bounded pool. */
public final class InputSourceBridgeRegression {
    private static final Godot godot = new Godot();

    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    private static void same(Object expected, Object actual, String message) {
        if (!expected.equals(actual)) throw new AssertionError(message + ": expected " + expected + ", got " + actual);
    }

    private static InputEventRunnable obtain() {
        InputEventRunnable event = InputEventRunnable.obtain();
        check(event != null, "original input pool was exhausted");
        return event;
    }

    private static InputEventRunnable mouse(int source, int action) {
        InputEventRunnable event = obtain();
        int previous = GodotInputSourceBridge.pushSource(source);
        try {
            event.setMouseEvent(action, 2, 11, 12, 0, 0, false, false, 1, 0, 0);
        } finally {
            GodotInputSourceBridge.popSource(previous);
        }
        return event;
    }

    private static InputEventRunnable key(int source, int code) {
        InputEventRunnable event = obtain();
        int previous = GodotInputSourceBridge.pushSource(source);
        try {
            event.setKeyEvent(code, code, code, true, false);
        } finally {
            GodotInputSourceBridge.popSource(previous);
        }
        return event;
    }

    private static void ui(Runnable action) throws Exception {
        AtomicReference<Throwable> error = new AtomicReference<>();
        Thread thread = new Thread(() -> {
            try { action.run(); } catch (Throwable failure) { error.set(failure); }
        }, "input-ui-fixture");
        thread.start();
        thread.join();
        if (error.get() != null) throw new AssertionError("UI dispatch failed", error.get());
    }

    private static void clearConsumer() {
        GodotLib.flush();
        GodotLib.delivered.clear();
        Callable.boundaries.clear();
    }

    private static void poolCapacity() {
        List<InputEventRunnable> held = new ArrayList<>();
        Set<InputEventRunnable> unique = Collections.newSetFromMap(new IdentityHashMap<>());
        for (int index = 0; index < 1200; index++) {
            InputEventRunnable event = obtain();
            check(unique.add(event), "one pooled runnable was released twice");
            held.add(event);
        }
        check(InputEventRunnable.obtain() == null, "original 1200-entry pool limit changed");
        for (InputEventRunnable event : held) event.run(); // Original invalid-event finally recycles it.
    }

    private static void rejectedMouseActionsDoNotAcquire() throws Exception {
        Field field = Unsafe.class.getDeclaredField("theUnsafe");
        field.setAccessible(true);
        GodotInputHandler handler = (GodotInputHandler) ((Unsafe) field.get(null)).allocateInstance(GodotInputHandler.class);
        for (int index = 0; index < 1400; index++) {
            for (int action : new int[] {11, 12, 99}) {
                check(!handler.handleMouseEvent(action, 0, 0, 0, 0, 0, false, false, 1, 0, 0), "unsupported mouse action accepted");
            }
        }
        poolCapacity();
        check(handler.handleMouseEvent(0, 1, 1, 2, 0, 0, false, false, 1, 0, 0), "supported path no longer reaches original handler");
        same(List.of("mouse/0/1"), GodotLib.buffered, "original JNI arguments changed");
        clearConsumer();
    }

    private static void classifierProvenance() {
        new InputDevice(7, false);
        new InputDevice(8, true);
        new InputDevice(9, false, InputDevice.SOURCE_GAMEPAD | InputDevice.SOURCE_KEYBOARD);
        same(3, GodotInputSourceBridge.keySource(29, new KeyEvent(7, InputDevice.SOURCE_KEYBOARD | InputDevice.SOURCE_DPAD, 0)), "hardware keyboard");
        same(4, GodotInputSourceBridge.keySource(29, new KeyEvent(-1, InputDevice.SOURCE_KEYBOARD, 0)), "built-in keyboard must not drive hardware policy");
        same(4, GodotInputSourceBridge.keySource(29, new KeyEvent(7, InputDevice.SOURCE_KEYBOARD, KeyEvent.FLAG_SOFT_KEYBOARD)), "IME key");
        same(4, GodotInputSourceBridge.keySource(29, new KeyEvent(8, InputDevice.SOURCE_KEYBOARD, 0)), "virtual device");
        same(4, GodotInputSourceBridge.keySource(4, new KeyEvent(7, InputDevice.SOURCE_KEYBOARD, 0)), "Back key");
        same(4, GodotInputSourceBridge.keySource(24, new KeyEvent(7, InputDevice.SOURCE_KEYBOARD, 0)), "volume key");
        same(4, GodotInputSourceBridge.keySource(96, new KeyEvent(7, InputDevice.SOURCE_GAMEPAD | InputDevice.SOURCE_KEYBOARD, 0)), "gamepad key");
        same(4, GodotInputSourceBridge.keySource(29, new KeyEvent(9, InputDevice.SOURCE_KEYBOARD, 0)), "gamepad keyboard-shaped event");
        same(2, GodotInputSourceBridge.motionSource(new MotionEvent(InputDevice.SOURCE_MOUSE, 7, 3, 7)), "hardware hover");
        same(2, GodotInputSourceBridge.motionSource(new MotionEvent(InputDevice.SOURCE_MOUSE_RELATIVE, 7, 3, 2)), "relative mouse");
        same(2, GodotInputSourceBridge.motionSource(new MotionEvent(InputDevice.SOURCE_TOUCHPAD, 7, 1, 7)), "real touchpad finger is hardware");
        same(2, GodotInputSourceBridge.motionSource(new MotionEvent(InputDevice.SOURCE_MOUSE, 7, 1, 7)), "mouse source takes priority over finger tool");
        same(4, GodotInputSourceBridge.motionSource(new MotionEvent(InputDevice.SOURCE_TOUCHPAD, -1, 1, 7)), "virtual touchpad finger is not touchscreen");
        same(4, GodotInputSourceBridge.motionSource(new MotionEvent(InputDevice.SOURCE_MOUSE, 99, 3, 7)), "missing mouse device is not hardware");
        same(4, GodotInputSourceBridge.motionSource(new MotionEvent(InputDevice.SOURCE_MOUSE, -1, 3, 0)), "unmarked synthetic mouse");
        same(1, GodotInputSourceBridge.motionSource(new MotionEvent(InputDevice.SOURCE_TOUCHSCREEN, 0, 1, 0)), "finger");
        same(1, GodotInputSourceBridge.motionSource(new MotionEvent(InputDevice.SOURCE_STYLUS, 0, 2, 0)), "stylus");
    }

    private static void orderedBoundariesAndPoolOwnership() throws Exception {
        GodotInputSourceBridge.bind(godot, 77, true);
        clearConsumer();
        AtomicReference<InputEventRunnable> queued = new AtomicReference<>();
        ui(() -> {
            InputEventRunnable event = mouse(1, 0);
            queued.set(event);
            event.run();
        });
        check(godot.queue.peekFirst() == queued.get(), "bridge did not queue the same pooled object");
        check(GodotLib.buffered.isEmpty(), "UI event reached JNI before render boundary");
        InputEventRunnable other = key(3, 29);
        check(other != queued.get(), "requeued event was returned to pool before dispatch");
        ui(other);
        ui(() -> mouse(2, 7).run());
        ui(() -> mouse(2, 2).run());
        ui(() -> {
            int previous = GodotInputSourceBridge.pushSource(1);
            try {
                int nested = GodotInputSourceBridge.pushMotionSource(new MotionEvent(InputDevice.SOURCE_MOUSE, -1, 3, 1));
                try {
                    InputEventRunnable event = obtain();
                    event.setMouseEvent(1, 0, 11, 12, 0, 0, false, false, 0, 0, 0);
                    event.run();
                } finally { GodotInputSourceBridge.popSource(nested); }
            } finally { GodotInputSourceBridge.popSource(previous); }
        });
        godot.drain();
        GodotLib.flush();
        same(List.of("1:mouse/0/2", "3:key/29/true", "2:mouse/7/2", "2:mouse/2/2", "1:mouse/1/0"), GodotLib.delivered, "consumer-visible provenance/order");
        same(List.of(1, 3, 2, 1), Callable.boundaries, "only source boundaries should emit");
        poolCapacity();
    }

    private static void touchSetterAndUntrackedReuse() throws Exception {
        clearConsumer();
        ui(() -> {
            int previous = GodotInputSourceBridge.pushSource(1);
            try {
                InputEventRunnable event = obtain();
                event.setTouchEvent(new MotionEvent(InputDevice.SOURCE_TOUCHSCREEN, 0, 1, 0), 0, false);
                event.run();
            } finally { GodotInputSourceBridge.popSource(previous); }
        });
        godot.drain();
        GodotLib.flush();
        same(List.of("1:touch/0"), GodotLib.delivered, "touch setter provenance");
        clearConsumer();
        ui(() -> {
            InputEventRunnable sensor = obtain();
            sensor.setSensorEvent(1, 0, 0, 0);
            sensor.run();
            check(GodotLib.lastDispatchThread == Thread.currentThread(), "sensor was rerouted");
            InputEventRunnable joystick = obtain();
            joystick.setJoystickAxisEvent(0, 0, 1);
            joystick.run();
            check(GodotLib.lastDispatchThread == Thread.currentThread(), "joystick was rerouted");
        });
        check(godot.queue.isEmpty(), "non-pointer/key event was added to render queue");
        check(Callable.boundaries.isEmpty(), "pooled source leaked into sensor/joystick reuse");
    }

    private static void lifecycleEpochDiscardsOldQueues() throws Exception {
        clearConsumer();
        ui(() -> mouse(2, 0).run());
        GodotInputSourceBridge.setActive(godot, false);
        GodotInputSourceBridge.setActive(godot, true);
        ui(() -> key(3, 30).run());
        godot.drain();
        GodotLib.flush();
        same(List.of("3:key/30/true"), GodotLib.delivered, "stale paused input reached the new session");
        same(List.of(0, 3), Callable.boundaries, "resume must reset source before new activity");
        poolCapacity();
        clearConsumer();
        ui(() -> mouse(2, 0).run());
        GodotInputSourceBridge.bind(godot, 77, true);
        godot.drain();
        check(GodotLib.buffered.isEmpty(), "old binding queue survived rebind");
        poolCapacity();
        clearConsumer();
        Callable.duringBoundary = () -> GodotInputSourceBridge.bind(godot, 77, true);
        ui(() -> mouse(2, 0).run());
        godot.drain();
        check(GodotLib.buffered.isEmpty(), "synchronous receiver rebind did not discard the old event");
        same(List.of(2, 0), Callable.boundaries, "reentrant bind must leave the new epoch's Unknown source installed");
        poolCapacity();
    }

    private static void noSinkPreservesOriginalScheduling() throws Exception {
        clearConsumer();
        ui(() -> mouse(2, 0).run());
        GodotInputSourceBridge.unbind(godot);
        godot.drain();
        check(GodotLib.buffered.isEmpty(), "destroyed binding queue reached JNI");
        clearConsumer();
        ui(() -> {
            mouse(2, 2).run();
            check(GodotLib.lastDispatchThread == Thread.currentThread(), "unbound bridge changed engine scheduling");
        });
        check(godot.queue.isEmpty() && Callable.boundaries.isEmpty(), "unbound bridge scheduled or emitted");
        poolCapacity();
    }

    public static void main(String[] args) throws Exception {
        Callable.renderThread = Thread.currentThread();
        rejectedMouseActionsDoNotAcquire();
        classifierProvenance();
        orderedBoundariesAndPoolOwnership();
        touchSetterAndUntrackedReuse();
        lifecycleEpochDiscardsOldQueues();
        noSinkPreservesOriginalScheduling();
        System.out.println("Actual Godot runnable provenance, order, lifecycle and pool regression passed.");
    }
}
