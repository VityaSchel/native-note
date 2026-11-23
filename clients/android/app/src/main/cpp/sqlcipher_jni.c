#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "sqlite3.h"

#define RAW_KEY_LENGTH 32
#define RAW_KEY_LITERAL_LENGTH (2 * RAW_KEY_LENGTH + 3)

static void *(*const volatile wipe_memset)(void *, int, size_t) = memset;

static void wipe(void *bytes, size_t length) {
	wipe_memset(bytes, 0, length);
}

static sqlite3 *connection(jlong handle) {
	return (sqlite3 *)(intptr_t)handle;
}

static sqlite3_stmt *statement(jlong handle) {
	return (sqlite3_stmt *)(intptr_t)handle;
}

static void throw_sqlite(JNIEnv *env, int code, const char *message) {
	jclass type = (*env)->FindClass(env, "dev/hloth/nativenote/storage/SQLiteException");
	if (type == NULL) {
		return;
	}
	jmethodID init = (*env)->GetMethodID(env, type, "<init>", "(ILjava/lang/String;)V");
	jstring text = (*env)->NewStringUTF(env, message);
	if (init == NULL || text == NULL) {
		return;
	}
	jobject exception = (*env)->NewObject(env, type, init, (jint)code, text);
	if (exception != NULL) {
		(*env)->Throw(env, (jthrowable)exception);
	}
}

static void throw_from(JNIEnv *env, sqlite3 *db) {
	throw_sqlite(env, sqlite3_errcode(db), sqlite3_errmsg(db));
}

static char *terminated_copy(JNIEnv *env, jbyteArray bytes) {
	const jsize length = (*env)->GetArrayLength(env, bytes);
	char *copy = malloc((size_t)length + 1);
	if (copy == NULL) {
		throw_sqlite(env, SQLITE_NOMEM, sqlite3_errstr(SQLITE_NOMEM));
		return NULL;
	}
	(*env)->GetByteArrayRegion(env, bytes, 0, length, (jbyte *)copy);
	copy[length] = '\0';
	return copy;
}

static jbyteArray byte_array(JNIEnv *env, const void *bytes, int length) {
	jbyteArray array = (*env)->NewByteArray(env, length);
	if (array != NULL && length > 0) {
		(*env)->SetByteArrayRegion(env, array, 0, length, (const jbyte *)bytes);
	}
	return array;
}

JNIEXPORT jlong JNICALL
Java_dev_hloth_nativenote_storage_SQLiteConnection_nativeOpen(JNIEnv *env, jclass type, jbyteArray path, jboolean create) {
	(void)type;
	char *file = terminated_copy(env, path);
	if (file == NULL) {
		return 0;
	}
	sqlite3 *db = NULL;
	const int flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0) | SQLITE_OPEN_FULLMUTEX;
	const int code = sqlite3_open_v2(file, &db, flags, NULL);
	free(file);
	if (code != SQLITE_OK) {
		throw_sqlite(env, code, db != NULL ? sqlite3_errmsg(db) : sqlite3_errstr(code));
		sqlite3_close_v2(db);
		return 0;
	}
	return (jlong)(intptr_t)db;
}

JNIEXPORT void JNICALL
Java_dev_hloth_nativenote_storage_SQLiteConnection_nativeKey(JNIEnv *env, jclass type, jlong handle, jbyteArray rawKey) {
	(void)type;
	static const char hex[] = "0123456789abcdef";
	uint8_t key[RAW_KEY_LENGTH];
	char literal[RAW_KEY_LITERAL_LENGTH];
	if ((*env)->GetArrayLength(env, rawKey) != RAW_KEY_LENGTH) {
		throw_sqlite(env, SQLITE_MISUSE, "the raw key must be 32 bytes");
		return;
	}
	(*env)->GetByteArrayRegion(env, rawKey, 0, RAW_KEY_LENGTH, (jbyte *)key);
	literal[0] = 'x';
	literal[1] = '\'';
	for (int index = 0; index < RAW_KEY_LENGTH; index++) {
		literal[2 + 2 * index] = hex[key[index] >> 4];
		literal[3 + 2 * index] = hex[key[index] & 0x0f];
	}
	literal[RAW_KEY_LITERAL_LENGTH - 1] = '\'';

	const int code = sqlite3_key_v2(connection(handle), "main", literal, RAW_KEY_LITERAL_LENGTH);
	wipe(key, sizeof key);
	wipe(literal, sizeof literal);
	if (code != SQLITE_OK) {
		throw_from(env, connection(handle));
	}
}

JNIEXPORT void JNICALL
Java_dev_hloth_nativenote_storage_SQLiteConnection_nativeExec(JNIEnv *env, jclass type, jlong handle, jbyteArray sql) {
	(void)type;
	char *text = terminated_copy(env, sql);
	if (text == NULL) {
		return;
	}
	const int code = sqlite3_exec(connection(handle), text, NULL, NULL, NULL);
	free(text);
	if (code != SQLITE_OK) {
		throw_from(env, connection(handle));
	}
}

JNIEXPORT jlong JNICALL
Java_dev_hloth_nativenote_storage_SQLiteConnection_nativePrepare(JNIEnv *env, jclass type, jlong handle, jbyteArray sql) {
	(void)type;
	char *text = terminated_copy(env, sql);
	if (text == NULL) {
		return 0;
	}
	sqlite3_stmt *prepared = NULL;
	const int code = sqlite3_prepare_v3(connection(handle), text, -1, 0, &prepared, NULL);
	free(text);
	if (code != SQLITE_OK) {
		throw_from(env, connection(handle));
		return 0;
	}
	if (prepared == NULL) {
		throw_sqlite(env, SQLITE_MISUSE, "the SQL holds no statement");
	}
	return (jlong)(intptr_t)prepared;
}

JNIEXPORT void JNICALL
Java_dev_hloth_nativenote_storage_SQLiteConnection_nativeClose(JNIEnv *env, jclass type, jlong handle) {
	(void)env;
	(void)type;
	sqlite3_close_v2(connection(handle));
}

static void check_bind(JNIEnv *env, jlong handle, int code) {
	if (code != SQLITE_OK) {
		throw_from(env, sqlite3_db_handle(statement(handle)));
	}
}

JNIEXPORT void JNICALL
Java_dev_hloth_nativenote_storage_SQLiteStatement_nativeBindNull(JNIEnv *env, jclass type, jlong handle, jint index) {
	(void)type;
	check_bind(env, handle, sqlite3_bind_null(statement(handle), index));
}

JNIEXPORT void JNICALL
Java_dev_hloth_nativenote_storage_SQLiteStatement_nativeBindLong(JNIEnv *env, jclass type, jlong handle, jint index, jlong value) {
	(void)type;
	check_bind(env, handle, sqlite3_bind_int64(statement(handle), index, value));
}

static void bind_bytes(JNIEnv *env, jlong handle, jint index, jbyteArray value, int asText) {
	const jsize length = (*env)->GetArrayLength(env, value);
	jbyte *bytes = (*env)->GetByteArrayElements(env, value, NULL);
	if (bytes == NULL) {
		return;
	}
	const int code = asText
		? sqlite3_bind_text(statement(handle), index, (const char *)bytes, length, SQLITE_TRANSIENT)
		: sqlite3_bind_blob(statement(handle), index, bytes, length, SQLITE_TRANSIENT);
	(*env)->ReleaseByteArrayElements(env, value, bytes, JNI_ABORT);
	check_bind(env, handle, code);
}

JNIEXPORT void JNICALL
Java_dev_hloth_nativenote_storage_SQLiteStatement_nativeBindText(JNIEnv *env, jclass type, jlong handle, jint index, jbyteArray utf8) {
	(void)type;
	bind_bytes(env, handle, index, utf8, 1);
}

JNIEXPORT void JNICALL
Java_dev_hloth_nativenote_storage_SQLiteStatement_nativeBindBlob(JNIEnv *env, jclass type, jlong handle, jint index, jbyteArray value) {
	(void)type;
	bind_bytes(env, handle, index, value, 0);
}

JNIEXPORT jboolean JNICALL
Java_dev_hloth_nativenote_storage_SQLiteStatement_nativeStep(JNIEnv *env, jclass type, jlong handle) {
	(void)type;
	const int code = sqlite3_step(statement(handle));
	if (code == SQLITE_ROW) {
		return JNI_TRUE;
	}
	if (code != SQLITE_DONE) {
		throw_from(env, sqlite3_db_handle(statement(handle)));
	}
	return JNI_FALSE;
}

JNIEXPORT jint JNICALL
Java_dev_hloth_nativenote_storage_SQLiteStatement_nativeColumnType(JNIEnv *env, jclass type, jlong handle, jint column) {
	(void)env;
	(void)type;
	return sqlite3_column_type(statement(handle), column);
}

JNIEXPORT jlong JNICALL
Java_dev_hloth_nativenote_storage_SQLiteStatement_nativeColumnLong(JNIEnv *env, jclass type, jlong handle, jint column) {
	(void)env;
	(void)type;
	return sqlite3_column_int64(statement(handle), column);
}

JNIEXPORT jbyteArray JNICALL
Java_dev_hloth_nativenote_storage_SQLiteStatement_nativeColumnText(JNIEnv *env, jclass type, jlong handle, jint column) {
	(void)type;
	const unsigned char *text = sqlite3_column_text(statement(handle), column);
	return byte_array(env, text, sqlite3_column_bytes(statement(handle), column));
}

JNIEXPORT jbyteArray JNICALL
Java_dev_hloth_nativenote_storage_SQLiteStatement_nativeColumnBlob(JNIEnv *env, jclass type, jlong handle, jint column) {
	(void)type;
	const void *blob = sqlite3_column_blob(statement(handle), column);
	return byte_array(env, blob, sqlite3_column_bytes(statement(handle), column));
}

JNIEXPORT void JNICALL
Java_dev_hloth_nativenote_storage_SQLiteStatement_nativeReset(JNIEnv *env, jclass type, jlong handle) {
	(void)env;
	(void)type;
	sqlite3_reset(statement(handle));
	sqlite3_clear_bindings(statement(handle));
}

JNIEXPORT void JNICALL
Java_dev_hloth_nativenote_storage_SQLiteStatement_nativeFinalize(JNIEnv *env, jclass type, jlong handle) {
	(void)env;
	(void)type;
	sqlite3_finalize(statement(handle));
}
