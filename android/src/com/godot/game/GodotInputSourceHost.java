package com.godot.game;

import org.godotengine.godot.Godot;
import org.godotengine.godot.input.GodotInputSourceBridge;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.SignalInfo;
import org.godotengine.godot.plugin.UsedByGodot;

import java.util.Collections;
import java.util.Set;

/** Opt-in, synchronous provenance boundaries for the full compatibility input policy. */
public final class GodotInputSourceHost extends GodotPlugin {
	private boolean resumed;
	private boolean focused;

	public GodotInputSourceHost(Godot godot) {
		super(godot);
	}

	@Override public String getPluginName() {
		return "GodotInputSourceHost";
	}

	@Override public Set<SignalInfo> getPluginSignals() {
		return Collections.singleton(new SignalInfo("android_input_source", Integer.class));
	}

	/** Connect the signal first; pass this singleton's GetInstanceId(), not the receiver's ID. */
	@UsedByGodot
	public synchronized void bindInputSource(long singletonObjectId) {
		GodotInputSourceBridge.bind(getGodot(), singletonObjectId, resumed && focused);
	}

	@Override public synchronized void onMainResume() {
		resumed = true;
		android.app.Activity activity = getActivity();
		if (activity != null) focused = activity.hasWindowFocus();
		GodotInputSourceBridge.setActive(getGodot(), resumed && focused);
	}

	@Override public synchronized void onMainPause() {
		resumed = false;
		GodotInputSourceBridge.setActive(getGodot(), false);
	}

	synchronized void onWindowFocusChanged(boolean hasFocus) {
		focused = hasFocus;
		GodotInputSourceBridge.setActive(getGodot(), resumed && focused);
	}

	@Override public synchronized void onMainDestroy() {
		resumed = false;
		focused = false;
		GodotInputSourceBridge.unbind(getGodot());
	}
}
