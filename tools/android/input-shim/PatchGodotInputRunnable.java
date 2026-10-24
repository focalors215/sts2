import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

import jdk.internal.org.objectweb.asm.ClassReader;
import jdk.internal.org.objectweb.asm.ClassVisitor;
import jdk.internal.org.objectweb.asm.ClassWriter;
import jdk.internal.org.objectweb.asm.FieldVisitor;
import jdk.internal.org.objectweb.asm.Label;
import jdk.internal.org.objectweb.asm.MethodVisitor;
import jdk.internal.org.objectweb.asm.Opcodes;

/** Build-time instrumentation only; no replacement of Godot's native dispatch or pool. */
public final class PatchGodotInputRunnable implements Opcodes {
    private static final String OWNER = "org/godotengine/godot/input/InputEventRunnable";
    private static final String BRIDGE = "org/godotengine/godot/input/GodotInputSourceBridge";
    private static final String SOURCE = "sts2InputSource";
    private static final String EPOCH = "sts2InputEpoch";
    private static final String ORIGINAL = "sts2RunOriginal";
    private static final Map<String, String> SETTERS = Map.of(
        "setMouseEvent", "(IIFFFFZZFFF)V",
        "setTouchEvent", "(Landroid/view/MotionEvent;IZ)V",
        "setMagnifyEvent", "(FFF)V",
        "setPanEvent", "(FFFF)V",
        "setJoystickButtonEvent", "(IIZ)V",
        "setJoystickAxisEvent", "(IIF)V",
        "setJoystickHatEvent", "(III)V",
        "setJoystickConnectionChangedEvent", "(IZLjava/lang/String;)V",
        "setKeyEvent", "(IIIZZ)V",
        "setSensorEvent", "(IFFF)V");
    private static final Set<String> CAPTURE = Set.of("setMouseEvent", "setTouchEvent", "setKeyEvent");

    private static final class Shape extends ClassVisitor {
        final Map<String, String> methods = new HashMap<>();
        final Map<String, String> fields = new HashMap<>();
        final Set<String> nativeDispatch = new HashSet<>();
        boolean patched;
        int captureCalls;
        int beforeCalls;
        int recycleCalls;
        int poolReleases;

        Shape() { super(ASM8); }

        @Override public void visit(int version, int access, String name, String signature,
                String parent, String[] interfaces) {
            require(OWNER.equals(name) && "java/lang/Object".equals(parent), "runnable class identity");
            require((access & ACC_FINAL) != 0 && version >= V1_8 && version <= V17, "runnable class version/flags");
        }

        @Override public FieldVisitor visitField(int access, String name, String descriptor,
                String signature, Object value) {
            require(fields.put(name, descriptor) == null, "duplicate field " + name);
            if (name.equals("STS2_INPUT_SOURCE_ABI")) {
                require(Integer.valueOf(1).equals(value), "source bridge ABI marker");
                patched = true;
            }
            return null;
        }

        @Override public MethodVisitor visitMethod(int access, String name, String descriptor,
                String signature, String[] exceptions) {
            require(methods.put(name, descriptor) == null, "overloaded runnable method " + name);
            if (name.equals("run")) require((access & (ACC_PUBLIC | ACC_STATIC)) == ACC_PUBLIC, "run flags");
            return new MethodVisitor(ASM8) {
                @Override public void visitMethodInsn(int opcode, String owner, String method,
                        String desc, boolean isInterface) {
                    if ((name.equals("run") || name.equals(ORIGINAL)) && owner.equals("org/godotengine/godot/GodotLib")) {
                        nativeDispatch.add(method + desc);
                    }
                    if ((name.equals("run") || name.equals(ORIGINAL)) && owner.equals(OWNER) && method.equals("recycle")) recycleCalls++;
                    if (name.equals("recycle") && owner.equals("androidx/core/util/Pools$Pool") && method.equals("release")) poolReleases++;
                    if (owner.equals(BRIDGE) && method.equals("capture")) captureCalls++;
                    if (owner.equals(BRIDGE) && method.equals("beforeRun")) beforeCalls++;
                }
            };
        }

        void validate() {
            for (var setter : SETTERS.entrySet()) {
                require(setter.getValue().equals(methods.get(setter.getKey())), setter.getKey() + " descriptor");
            }
            require(methods.keySet().stream().filter(n -> n.startsWith("set")).count() == SETTERS.size(), "event setter set");
            require(("()L" + OWNER + ";").equals(methods.get("obtain")), "obtain descriptor");
            require("(I)V".equals(methods.get("<init>")), "constructor descriptor");
            require("()V".equals(methods.get("run")) && "()V".equals(methods.get("recycle")), "run/recycle descriptors");
            require("Landroidx/core/util/Pools$Pool;".equals(fields.get("POOL")), "original pool field");
            require(("L" + OWNER + "$EventType;").equals(fields.get("currentEventType")), "event discriminator field");
            require(nativeDispatch.containsAll(Set.of("dispatchMouseEvent(IIFFFFZZFFF)V", "dispatchTouchEvent(III[FZ)V", "key(IIIZZ)V")), "original native dispatch calls");
            require(recycleCalls >= 2 && poolReleases == 1, "original finally/pool recycling");
            if (patched) {
                require("I".equals(fields.get(SOURCE)) && "J".equals(fields.get(EPOCH)), "source metadata fields");
                require("()V".equals(methods.get(ORIGINAL)) && captureCalls == 3 && beforeCalls == 1, "source instrumentation");
            } else {
                require(!fields.containsKey(SOURCE) && !fields.containsKey(EPOCH)
                    && !methods.containsKey(ORIGINAL) && captureCalls == 0 && beforeCalls == 0, "partial source instrumentation");
            }
        }
    }

    private static void require(boolean condition, String detail) {
        if (!condition) throw new IllegalArgumentException("unsupported Godot InputEventRunnable shape: " + detail);
    }

    private static void clearSource(MethodVisitor method) {
        method.visitVarInsn(ALOAD, 0);
        method.visitInsn(ICONST_M1);
        method.visitFieldInsn(PUTFIELD, OWNER, SOURCE, "I");
        method.visitVarInsn(ALOAD, 0);
        method.visitInsn(LCONST_0);
        method.visitFieldInsn(PUTFIELD, OWNER, EPOCH, "J");
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 2) throw new IllegalArgumentException("input.class output.class required");
        byte[] input = Files.readAllBytes(Path.of(args[0]));
        ClassReader reader = new ClassReader(input);
        Shape shape = new Shape();
        reader.accept(shape, 0);
        shape.validate();
        if (shape.patched) {
            Files.write(Path.of(args[1]), input);
            return;
        }

        // Existing instructions, frames, exception tables and pool classes stay intact.
        // Only straight-line setter/recycle hooks and a new small run wrapper are added.
        ClassWriter writer = new ClassWriter(reader, ClassWriter.COMPUTE_MAXS);
        reader.accept(new ClassVisitor(ASM8, writer) {
            @Override public MethodVisitor visitMethod(int access, String name, String descriptor,
                    String signature, String[] exceptions) {
                String outputName = name.equals("run") ? ORIGINAL : name;
                int outputAccess = name.equals("run") ? ACC_PRIVATE | ACC_SYNTHETIC : access;
                MethodVisitor method = super.visitMethod(outputAccess, outputName, descriptor, signature, exceptions);
                return new MethodVisitor(ASM8, method) {
                    @Override public void visitCode() {
                        super.visitCode();
                        if (CAPTURE.contains(name)) {
                            super.visitVarInsn(ALOAD, 0);
                            super.visitMethodInsn(INVOKESTATIC, BRIDGE, "capture", "(L" + OWNER + ";)V", false);
                        } else if (name.equals("recycle")) {
                            clearSource(this.mv);
                        }
                    }

                    @Override public void visitInsn(int opcode) {
                        if (name.equals("<init>") && opcode == RETURN) clearSource(this.mv);
                        super.visitInsn(opcode);
                    }
                };
            }

            @Override public void visitEnd() {
                super.visitField(ACC_STATIC | ACC_FINAL | ACC_SYNTHETIC, "STS2_INPUT_SOURCE_ABI", "I", null, 1).visitEnd();
                super.visitField(0, SOURCE, "I", null, null).visitEnd();
                super.visitField(0, EPOCH, "J", null, null).visitEnd();
                MethodVisitor method = super.visitMethod(ACC_PUBLIC, "run", "()V", null, null);
                method.visitCode();
                method.visitVarInsn(ALOAD, 0);
                method.visitVarInsn(ALOAD, 0);
                method.visitFieldInsn(GETFIELD, OWNER, SOURCE, "I");
                method.visitMethodInsn(INVOKESTATIC, BRIDGE, "beforeRun", "(L" + OWNER + ";I)I", false);
                method.visitVarInsn(ISTORE, 1);
                method.visitVarInsn(ILOAD, 1);
                Label run = new Label();
                method.visitJumpInsn(IFEQ, run);
                method.visitVarInsn(ILOAD, 1);
                method.visitInsn(ICONST_2);
                Label done = new Label();
                method.visitJumpInsn(IF_ICMPNE, done);
                method.visitVarInsn(ALOAD, 0);
                method.visitMethodInsn(INVOKESPECIAL, OWNER, "recycle", "()V", false);
                method.visitLabel(done);
                method.visitFrame(F_APPEND, 1, new Object[] {INTEGER}, 0, null);
                method.visitInsn(RETURN);
                method.visitLabel(run);
                method.visitFrame(F_SAME, 0, null, 0, null);
                method.visitVarInsn(ALOAD, 0);
                method.visitMethodInsn(INVOKESPECIAL, OWNER, ORIGINAL, "()V", false);
                method.visitInsn(RETURN);
                method.visitMaxs(0, 0);
                method.visitEnd();
                super.visitEnd();
            }
        }, 0);
        byte[] patched = writer.toByteArray();
        Shape result = new Shape();
        new ClassReader(patched).accept(result, 0);
        result.validate();
        require(result.patched, "missing transformed ABI marker");
        Files.write(Path.of(args[1]), patched);
    }
}
