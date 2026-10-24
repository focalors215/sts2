package android.view;

import java.util.HashMap;
import java.util.Map;

public final class InputDevice {
    public static final int SOURCE_KEYBOARD = 0x101, SOURCE_DPAD = 0x201, SOURCE_GAMEPAD = 0x401;
    public static final int SOURCE_TOUCHSCREEN = 0x1002, SOURCE_MOUSE = 0x2002, SOURCE_STYLUS = 0x4002;
    public static final int SOURCE_MOUSE_RELATIVE = 0x20004, SOURCE_TOUCHPAD = 0x100008, SOURCE_JOYSTICK = 0x1000010;
    private static final Map<Integer, InputDevice> devices = new HashMap<>();
    private final boolean virtual;
    private final int sources;
    public InputDevice(int id, boolean virtual) { this(id, virtual, 0); }
    public InputDevice(int id, boolean virtual, int sources) {
        this.virtual = virtual;
        this.sources = sources;
        devices.put(id, this);
    }
    public static InputDevice getDevice(int id) { return devices.get(id); }
    public boolean isVirtual() { return virtual; }
    public boolean supportsSource(int source) { return (sources & source) == source; }
}
