package org.godotengine.godot;

import java.util.ArrayDeque;

/** Render queue fixture; the production bridge is loaded from the patched AAR. */
public final class Godot {
    public final ArrayDeque<Runnable> queue = new ArrayDeque<>();
    public synchronized void runOnRenderThread(Runnable event) { queue.addLast(event); }
    public void drain() {
        while (!queue.isEmpty()) queue.removeFirst().run();
    }
}
