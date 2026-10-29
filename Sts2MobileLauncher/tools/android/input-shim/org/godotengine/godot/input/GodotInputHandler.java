package org.godotengine.godot.input;

import android.content.Context;
import android.view.KeyEvent;
import android.view.MotionEvent;

import org.godotengine.godot.Godot;

/** Adds provenance scopes and rejects ignored mouse actions before pool acquisition. */
public class GodotInputHandler extends GodotInputHandlerBase {
    public GodotInputHandler(Context context, Godot godot) {
        super(context, godot);
    }

    @Override public boolean onTouchEvent(MotionEvent event) {
        int previous = GodotInputSourceBridge.pushSource(GodotInputSourceBridge.motionSource(event));
        try {
            return super.onTouchEvent(event);
        } finally {
            GodotInputSourceBridge.popSource(previous);
        }
    }

    @Override public boolean onGenericMotionEvent(MotionEvent event) {
        int previous = GodotInputSourceBridge.pushSource(GodotInputSourceBridge.motionSource(event));
        try {
            return super.onGenericMotionEvent(event);
        } finally {
            GodotInputSourceBridge.popSource(previous);
        }
    }

    /** Shell touch-to-mouse conversion; never a physical mouse activity boundary. */
    public boolean onSyntheticTouchMouseEvent(MotionEvent event) {
        int previous = GodotInputSourceBridge.pushSource(GodotInputSourceBridge.TOUCH);
        try {
            return super.onGenericMotionEvent(event);
        } finally {
            GodotInputSourceBridge.popSource(previous);
        }
    }

    @Override public boolean onKeyDown(int keyCode, KeyEvent event) {
        int previous = GodotInputSourceBridge.pushSource(GodotInputSourceBridge.keySource(keyCode, event));
        try {
            return super.onKeyDown(keyCode, event);
        } finally {
            GodotInputSourceBridge.popSource(previous);
        }
    }

    @Override public boolean onKeyUp(int keyCode, KeyEvent event) {
        int previous = GodotInputSourceBridge.pushSource(GodotInputSourceBridge.keySource(keyCode, event));
        try {
            return super.onKeyUp(keyCode, event);
        } finally {
            GodotInputSourceBridge.popSource(previous);
        }
    }

    // GestureDetector may invoke a delayed long-press outside the high-level scope.
    @Override boolean handleMouseEvent(MotionEvent event, int action, int buttons, boolean doubleClick) {
        int previous = GodotInputSourceBridge.pushMotionSource(event);
        try {
            return super.handleMouseEvent(event, action, buttons, doubleClick);
        } finally {
            GodotInputSourceBridge.popSource(previous);
        }
    }

    @Override boolean handleTouchEvent(MotionEvent event, int action, boolean doubleTap) {
        int previous = GodotInputSourceBridge.pushMotionSource(event);
        try {
            return super.handleTouchEvent(event, action, doubleTap);
        } finally {
            GodotInputSourceBridge.popSource(previous);
        }
    }

    @Override boolean handleMouseEvent(int eventAction, int buttonsMask, float x, float y,
            float deltaX, float deltaY, boolean doubleClick, boolean sourceMouseRelative,
            float pressure, float tiltX, float tiltY) {
        switch (eventAction) {
            case MotionEvent.ACTION_CANCEL:
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_DOWN:
            case MotionEvent.ACTION_HOVER_ENTER:
            case MotionEvent.ACTION_HOVER_EXIT:
            case MotionEvent.ACTION_HOVER_MOVE:
            case MotionEvent.ACTION_MOVE:
            case MotionEvent.ACTION_SCROLL:
                return super.handleMouseEvent(eventAction, buttonsMask, x, y, deltaX, deltaY,
                        doubleClick, sourceMouseRelative, pressure, tiltX, tiltY);
            default:
                return false;
        }
    }
}
