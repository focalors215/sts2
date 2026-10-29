package android.view;

public final class MotionEvent {
    public static final int ACTION_DOWN = 0, ACTION_UP = 1, ACTION_MOVE = 2, ACTION_CANCEL = 3;
    public static final int ACTION_HOVER_MOVE = 7, ACTION_SCROLL = 8, ACTION_BUTTON_PRESS = 11, ACTION_BUTTON_RELEASE = 12;
    public static final int TOOL_TYPE_UNKNOWN = 0, TOOL_TYPE_FINGER = 1, TOOL_TYPE_STYLUS = 2, TOOL_TYPE_MOUSE = 3, TOOL_TYPE_ERASER = 4;
    private final int source, device, tool, action;
    public MotionEvent(int source, int device, int tool, int action) { this.source = source; this.device = device; this.tool = tool; this.action = action; }
    public int getPointerCount() { return 1; }
    public int getToolType(int index) { return tool; }
    public boolean isFromSource(int value) { return (source & value) == value; }
    public int getSource() { return source; }
    public int getDeviceId() { return device; }
    public InputDevice getDevice() { return InputDevice.getDevice(device); }
    public int getActionIndex() { return 0; }
    public int getActionMasked() { return action; }
    public int getPointerId(int index) { return 0; }
    public float getX(int index) { return 10; }
    public float getY(int index) { return 20; }
    public float getPressure(int index) { return 1; }
    public float getOrientation() { return 0; }
    public float getAxisValue(int axis) { return 0; }
}
