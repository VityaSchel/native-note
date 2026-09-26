#ifndef SQLCIPHER_CODEC_H
#define SQLCIPHER_CODEC_H

struct sqlite3;

int sqlite3_key_v2(struct sqlite3 *db, const char *zDbName, const void *pKey, int nKey);
int sqlite3_rekey_v2(struct sqlite3 *db, const char *zDbName, const void *pKey, int nKey);

#endif
