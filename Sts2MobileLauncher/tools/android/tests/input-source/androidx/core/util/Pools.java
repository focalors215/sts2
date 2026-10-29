package androidx.core.util;

public final class Pools {
    public interface Pool<T> {
        T acquire();
        boolean release(T instance);
    }
}
