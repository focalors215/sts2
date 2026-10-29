// JNI entry points for com.godot.game.FrpBridge. Strings coming back from Go are
// returned as UTF-8 byte arrays: NewStringUTF only accepts modified UTF-8 and can
// abort on 4-byte sequences (e.g. emoji in another host's room card).
#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include "_cgo_export.h"

static char *dup_utf(JNIEnv *env, jstring value) {
	if (value == NULL) return strdup("");
	const char *chars = (*env)->GetStringUTFChars(env, value, NULL);
	char *copy = strdup(chars ? chars : "");
	if (chars) (*env)->ReleaseStringUTFChars(env, value, chars);
	return copy;
}

static jbyteArray take_bytes(JNIEnv *env, char *value) {
	if (value == NULL) return NULL;
	jsize length = (jsize)strlen(value);
	jbyteArray out = (*env)->NewByteArray(env, length);
	if (out != NULL) (*env)->SetByteArrayRegion(env, out, 0, length, (const jbyte *)value);
	free(value);
	return out;
}

JNIEXPORT jbyteArray JNICALL Java_com_godot_game_FrpBridge_nativeStart(JNIEnv *env, jclass cls, jstring configPath) {
	char *path = dup_utf(env, configPath);
	char *error = Sts2FrpStart(path);
	free(path);
	return take_bytes(env, error);
}

JNIEXPORT jbyteArray JNICALL Java_com_godot_game_FrpBridge_nativeStatus(JNIEnv *env, jclass cls, jstring proxyName) {
	char *name = dup_utf(env, proxyName);
	char *status = Sts2FrpStatus(name);
	free(name);
	return take_bytes(env, status);
}

JNIEXPORT void JNICALL Java_com_godot_game_FrpBridge_nativeStop(JNIEnv *env, jclass cls) {
	Sts2FrpStop();
}

JNIEXPORT jint JNICALL Java_com_godot_game_FrpBridge_nativeRoomServe(JNIEnv *env, jclass cls, jstring info) {
	char *card = dup_utf(env, info);
	int port = Sts2RoomServe(card);
	free(card);
	return port;
}

JNIEXPORT void JNICALL Java_com_godot_game_FrpBridge_nativeRoomStopServe(JNIEnv *env, jclass cls) {
	Sts2RoomStopServe();
}

JNIEXPORT jbyteArray JNICALL Java_com_godot_game_FrpBridge_nativeRoomScan(JNIEnv *env, jclass cls, jstring server, jint firstPort, jint count, jint timeoutMs) {
	char *host = dup_utf(env, server);
	char *rooms = Sts2RoomScan(host, firstPort, count, timeoutMs);
	free(host);
	return take_bytes(env, rooms);
}
