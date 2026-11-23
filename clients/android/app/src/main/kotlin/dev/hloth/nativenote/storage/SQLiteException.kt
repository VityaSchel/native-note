package dev.hloth.nativenote.storage

class SQLiteException(val code: Int, message: String) : Exception(message)
