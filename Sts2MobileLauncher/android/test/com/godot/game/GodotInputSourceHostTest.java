package com.godot.game;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import android.app.Activity;
import android.app.Application;
import android.view.InputDevice;
import android.view.KeyEvent;
import android.view.MotionEvent;

import org.godotengine.godot.Godot;
import org.godotengine.godot.GodotLib;
import org.godotengine.godot.input.GodotInputHandler;
import org.godotengine.godot.input.GodotInputSourceBridge;
import org.godotengine.godot.variant.Callable;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;
import org.robolectric.annotation.Implementation;
import org.robolectric.annotation.Implements;
import org.robolectric.shadow.api.Shadow;
import org.robolectric.shadows.InputDeviceBuilder;
import org.robolectric.shadows.ShadowInputEvent;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Real patched Java input handlers with native calls observed at the consumer boundary. */
@RunWith(RobolectricTestRunner.class)
@Config(manifest = Config.NONE, application = Application.class, sdk = 35,
	shadows = {GodotInputSourceHostTest.Engine.class, GodotInputSourceHostTest.NativeInput.class,
		GodotInputSourceHostTest.Signal.class})
public class GodotInputSourceHostTest {
	private static final ArrayDeque<Runnable> renderQueue = new ArrayDeque<>();
	private static final List<String> buffered = new ArrayList<>();
	private static final List<String> delivered = new ArrayList<>();
	private static final List<Integer> boundaries = new ArrayList<>();
	private static int source;
	private static Thread renderThread;
	private static Activity activity;
	private static InputDevice hardwareDevice;
	private ExecutorService renderer;
	private Godot godot;
	private GodotInputHandler input;

	@Before public void setUp() throws Exception {
		renderQueue.clear();
		buffered.clear();
		delivered.clear();
		boundaries.clear();
		source = 0;
		activity = Robolectric.buildActivity(Activity.class).setup().get();
		hardwareDevice = InputDeviceBuilder.newBuilder().setId(7).setName("Physical input fixture")
			.setSources(InputDevice.SOURCE_KEYBOARD | InputDevice.SOURCE_DPAD | InputDevice.SOURCE_MOUSE | InputDevice.SOURCE_TOUCHPAD)
			.setExternal(true).build();
		godot = Shadow.newInstanceOf(Godot.class);
		input = new GodotInputHandler(RuntimeEnvironment.getApplication(), godot);
		renderer = Executors.newSingleThreadExecutor();
		renderer.submit(() -> {
			renderThread = Thread.currentThread();
			GodotInputSourceBridge.bind(godot, 77, true);
		}).get();
		boundaries.clear();
	}

	@After public void tearDown() throws Exception {
		GodotInputSourceBridge.unbind(godot);
		drain();
		renderer.shutdownNow();
		activity.finish();
	}

	private void drain() throws Exception {
		renderer.submit(() -> {
			while (!renderQueue.isEmpty()) renderQueue.removeFirst().run();
			flush();
		}).get();
	}

	private static void flush() {
		for (String event : buffered) delivered.add(source + ":" + event);
		buffered.clear();
	}

	private static MotionEvent pointer(int action, int eventSource, int tool, int buttons, int device) {
		MotionEvent.PointerProperties property = new MotionEvent.PointerProperties();
		property.id = 0;
		property.toolType = tool;
		MotionEvent.PointerCoords coordinates = new MotionEvent.PointerCoords();
		coordinates.x = 100;
		coordinates.y = 80;
		coordinates.pressure = action == MotionEvent.ACTION_UP ? 0 : 1;
		MotionEvent event = MotionEvent.obtain(10, 10, action, 1,
			new MotionEvent.PointerProperties[] {property}, new MotionEvent.PointerCoords[] {coordinates},
			0, buttons, 1, 1, device, 0, eventSource, 0);
		// Robolectric's InputEvent shadow stores its device separately from deviceId.
		Shadow.<ShadowInputEvent>extract(event).setDevice(device == 7 ? hardwareDevice : null);
		return event;
	}

	private void pointerPair(boolean synthetic) {
		for (int action : new int[] {MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP}) {
			MotionEvent event = pointer(action, synthetic ? InputDevice.SOURCE_MOUSE : InputDevice.SOURCE_TOUCHSCREEN,
				synthetic ? MotionEvent.TOOL_TYPE_MOUSE : MotionEvent.TOOL_TYPE_FINGER,
				synthetic && action == MotionEvent.ACTION_DOWN ? MotionEvent.BUTTON_SECONDARY : 0, 0);
			try {
				assertTrue(synthetic ? input.onSyntheticTouchMouseEvent(event) : input.onTouchEvent(event));
			} finally {
				event.recycle();
			}
		}
	}

	private void keyPair(int code, int device, int flags, int eventSource) {
		KeyEvent down = new KeyEvent(10, 10, KeyEvent.ACTION_DOWN, code, 0, 0, device, 0, flags, eventSource);
		KeyEvent up = KeyEvent.changeAction(down, KeyEvent.ACTION_UP);
		Shadow.<ShadowInputEvent>extract(down).setDevice(device == 7 ? hardwareDevice : null);
		Shadow.<ShadowInputEvent>extract(up).setDevice(device == 7 ? hardwareDevice : null);
		input.onKeyDown(code, down);
		input.onKeyUp(code, up);
	}

	@Test public void originalHandlersCarryTouchMouseKeyboardAndSyntheticProvenanceInOrder() throws Exception {
		pointerPair(false);
		MotionEvent hover = pointer(MotionEvent.ACTION_HOVER_MOVE, InputDevice.SOURCE_MOUSE, MotionEvent.TOOL_TYPE_MOUSE, 0, 7);
		try { assertTrue(input.onGenericMotionEvent(hover)); } finally { hover.recycle(); }
		keyPair(KeyEvent.KEYCODE_A, 7, 0, InputDevice.SOURCE_KEYBOARD | InputDevice.SOURCE_DPAD);
		pointerPair(true);
		keyPair(KeyEvent.KEYCODE_B, -1, 0, InputDevice.SOURCE_KEYBOARD);
		assertTrue("JNI must wait for the render-thread source boundary", buffered.isEmpty());
		drain();
		assertEquals(List.of("1:touch/0", "1:touch/1", "2:mouse/7/0", "3:key/29/true", "3:key/29/false",
			"1:mouse/0/2", "1:mouse/1/0", "4:key/30/true", "4:key/30/false"), delivered);
		assertEquals(List.of(1, 2, 3, 1, 4), boundaries);
	}

	@Test public void realTouchpadFingerUsesHardwareWhileMissingDevicesStayVirtualAndSyntheticStaysTouch() throws Exception {
		MotionEvent touchpad = pointer(MotionEvent.ACTION_HOVER_MOVE, InputDevice.SOURCE_TOUCHPAD, MotionEvent.TOOL_TYPE_FINGER, 0, 7);
		MotionEvent unknownMouse = pointer(MotionEvent.ACTION_HOVER_MOVE, InputDevice.SOURCE_MOUSE, MotionEvent.TOOL_TYPE_MOUSE, 0, 99);
		MotionEvent synthetic = pointer(MotionEvent.ACTION_HOVER_MOVE, InputDevice.SOURCE_MOUSE, MotionEvent.TOOL_TYPE_FINGER, 0, 0);
		try {
			assertTrue(input.onGenericMotionEvent(touchpad));
			assertTrue(input.onGenericMotionEvent(unknownMouse));
			assertTrue(input.onSyntheticTouchMouseEvent(synthetic));
		} finally {
			touchpad.recycle();
			unknownMouse.recycle();
			synthetic.recycle();
		}
		drain();
		assertEquals(List.of("2:mouse/7/0", "4:mouse/7/0", "1:mouse/7/0"), delivered);
		assertEquals(List.of(2, 4, 1), boundaries);
	}

	@Test public void pluginResumeAndFocusEpochsRejectInputQueuedBeforePauseWithoutAnotherReady() throws Exception {
		GodotInputSourceHost plugin = new GodotInputSourceHost(godot);
		assertEquals("GodotInputSourceHost", plugin.getPluginName());
		assertEquals("android_input_source", plugin.getPluginSignals().iterator().next().getName());
		plugin.onMainResume();
		plugin.onWindowFocusChanged(true);
		renderer.submit(() -> plugin.bindInputSource(77)).get();
		drain();
		boundaries.clear();
		MotionEvent old = pointer(MotionEvent.ACTION_DOWN, InputDevice.SOURCE_MOUSE, MotionEvent.TOOL_TYPE_MOUSE, 1, 7);
		try { input.onGenericMotionEvent(old); } finally { old.recycle(); }
		plugin.onMainPause();
		plugin.onMainResume();
		plugin.onWindowFocusChanged(true);
		keyPair(KeyEvent.KEYCODE_A, 7, 0, InputDevice.SOURCE_KEYBOARD);
		drain();
		assertEquals(List.of("3:key/29/true", "3:key/29/false"), delivered);
		assertEquals(List.of(0, 3), boundaries);
		delivered.clear();
		boundaries.clear();
		keyPair(KeyEvent.KEYCODE_B, 7, 0, InputDevice.SOURCE_KEYBOARD);
		plugin.onWindowFocusChanged(false);
		plugin.onWindowFocusChanged(true);
		drain();
		assertTrue("focus-lost queue must not reach the new session", delivered.isEmpty());
		assertEquals(List.of(0), boundaries);
		plugin.onMainDestroy();
	}

	@Test public void imeVolumeBackAndBuiltInKeysRemainVirtualOnTheOriginalKeyRoute() throws Exception {
		keyPair(KeyEvent.KEYCODE_A, 7, KeyEvent.FLAG_SOFT_KEYBOARD, InputDevice.SOURCE_KEYBOARD);
		keyPair(KeyEvent.KEYCODE_B, -1, 0, InputDevice.SOURCE_KEYBOARD);
		keyPair(KeyEvent.KEYCODE_BACK, 7, 0, InputDevice.SOURCE_KEYBOARD);
		keyPair(KeyEvent.KEYCODE_VOLUME_UP, 7, 0, InputDevice.SOURCE_KEYBOARD);
		drain();
		assertEquals(List.of(4), boundaries);
		assertEquals(8, delivered.size());
		for (String event : delivered) assertTrue(event, event.startsWith("4:key/"));
	}

	@Implements(value = Godot.class, isInAndroidSdk = false)
	public static class Engine {
		@Implementation protected void runOnRenderThread(Runnable action) { renderQueue.addLast(action); }
		@Implementation protected Activity getActivity() { return activity; }
	}

	@Implements(value = GodotLib.class, isInAndroidSdk = false)
	public static class NativeInput {
		@Implementation protected static boolean shouldDispatchInputToRenderThread() { return false; }
		@Implementation protected static void dispatchMouseEvent(int action, int buttons, float x, float y, float dx, float dy,
				boolean doubleTap, boolean relative, float pressure, float tiltX, float tiltY) {
			assertEquals(renderThread, Thread.currentThread());
			buffered.add("mouse/" + action + "/" + buttons);
		}
		@Implementation protected static void dispatchTouchEvent(int action, int pointer, int count, float[] positions, boolean doubleTap) {
			assertEquals(renderThread, Thread.currentThread());
			buffered.add("touch/" + action);
		}
		@Implementation protected static void key(int code, int unicode, int label, boolean pressed, boolean echo) {
			assertEquals(renderThread, Thread.currentThread());
			buffered.add("key/" + code + "/" + pressed);
		}
	}

	@Implements(value = Callable.class, isInAndroidSdk = false)
	public static class Signal {
		@Implementation protected static Object call(long objectId, String method, Object... arguments) {
			assertEquals(77, objectId);
			assertEquals("emit_signal", method);
			assertEquals("android_input_source", arguments[0]);
			assertEquals(renderThread, Thread.currentThread());
			flush();
			source = (Integer) arguments[1];
			boundaries.add(source);
			return null;
		}
	}

}
