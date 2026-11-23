#include <jni.h>
#include <stdlib.h>

#include "argon2.h"
#include "core.h"

JNIEXPORT jint JNICALL
Java_dev_hloth_nativenote_crypto_Argon2_hashId(JNIEnv *env, jclass type, jbyteArray password, jbyteArray salt, jint m, jint t, jint p, jbyteArray out) {
	(void)type;
	const size_t passwordLength = (size_t)(*env)->GetArrayLength(env, password);
	const size_t saltLength = (size_t)(*env)->GetArrayLength(env, salt);
	const size_t outLength = (size_t)(*env)->GetArrayLength(env, out);
	const size_t scratchLength = passwordLength + saltLength + outLength;
	uint8_t *scratch = malloc(scratchLength + 1);
	if (scratch == NULL) {
		return ARGON2_MEMORY_ALLOCATION_ERROR;
	}
	uint8_t *passwordBytes = scratch;
	uint8_t *saltBytes = passwordBytes + passwordLength;
	uint8_t *hash = saltBytes + saltLength;
	(*env)->GetByteArrayRegion(env, password, 0, (jsize)passwordLength, (jbyte *)passwordBytes);
	(*env)->GetByteArrayRegion(env, salt, 0, (jsize)saltLength, (jbyte *)saltBytes);

	const int code = argon2id_hash_raw((uint32_t)t, (uint32_t)m, (uint32_t)p, passwordBytes, passwordLength, saltBytes, saltLength, hash, outLength);
	if (code == ARGON2_OK) {
		(*env)->SetByteArrayRegion(env, out, 0, (jsize)outLength, (const jbyte *)hash);
	}

	secure_wipe_memory(scratch, scratchLength);
	free(scratch);
	return code;
}

JNIEXPORT jstring JNICALL
Java_dev_hloth_nativenote_crypto_Argon2_errorMessage(JNIEnv *env, jclass type, jint code) {
	(void)type;
	return (*env)->NewStringUTF(env, argon2_error_message(code));
}
