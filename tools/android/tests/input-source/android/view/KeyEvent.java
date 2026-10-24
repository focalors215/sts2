package android.view;

public final class KeyEvent {
    public static final int KEYCODE_A = 29, KEYCODE_BACK = 4, KEYCODE_VOLUME_UP = 24, KEYCODE_BUTTON_A = 96;
    public static final int FLAG_SOFT_KEYBOARD = 2, FLAG_VIRTUAL_HARD_KEY = 64;
    private final int device, source, flags;
    public KeyEvent(int device, int source, int flags) { this.device = device; this.source = source; this.flags = flags; }
    public int getDeviceId() { return device; }
    public int getFlags() { return flags; }
    public InputDevice getDevice() { return InputDevice.getDevice(device); }
    public boolean isFromSource(int value) { return (source & value) == value; }
    public static boolean isGamepadButton(int key) { return key >= 96 && key <= 110; }
}
