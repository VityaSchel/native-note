cmake_minimum_required(VERSION 4.1)
project(native-note C)

get_filename_component(repository "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../.." REALPATH)
set(argon2 ${repository}/clients/android/argon2)
set(libtomcrypt ${repository}/clients/android/libtomcrypt)
set(amalgamation ${repository}/clients/macos/native-note-kit/Sources/SQLCipher)

add_compile_options(-O3 -ffunction-sections -fdata-sections -ffile-prefix-map=${repository}=.)

function(reproducible_shared_library target)
	target_link_options(${target} PRIVATE -Wl,--build-id=none -Wl,--gc-sections)
	add_custom_command(TARGET ${target} POST_BUILD COMMAND ${CMAKE_OBJCOPY} --remove-section=.comment $<TARGET_FILE:${target}>)
endfunction()

add_library(argon2 SHARED
	argon2_jni.c
	${argon2}/src/argon2.c
	${argon2}/src/core.c
	${argon2}/src/encoding.c
	${argon2}/src/ref.c
	${argon2}/src/thread.c
	${argon2}/src/blake2/blake2b.c
)
target_include_directories(argon2 PRIVATE ${argon2}/include ${argon2}/src)
reproducible_shared_library(argon2)

file(GLOB_RECURSE libtomcrypt_sources CONFIGURE_DEPENDS ${libtomcrypt}/src/*.c)
add_library(tomcrypt STATIC ${libtomcrypt_sources})
target_include_directories(tomcrypt PUBLIC ${libtomcrypt}/src/headers)
target_compile_definitions(tomcrypt PRIVATE LTC_SOURCE)

set_source_files_properties(${amalgamation}/sqlite3.c PROPERTIES GENERATED TRUE)
add_library(sqlcipher SHARED sqlcipher_jni.c ${amalgamation}/sqlite3.c)
target_include_directories(sqlcipher PRIVATE ${amalgamation}/include)
target_compile_definitions(sqlcipher PRIVATE
	SQLITE_HAS_CODEC
	SQLCIPHER_CRYPTO_LIBTOMCRYPT
	SQLITE_EXTRA_INIT=sqlcipher_extra_init
	SQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown
	SQLITE_THREADSAFE=1
	SQLITE_TEMP_STORE=2
	SQLITE_DEFAULT_JOURNAL_SIZE_LIMIT=1048576
	SQLITE_ENABLE_FTS5
	SQLITE_OMIT_LOAD_EXTENSION
	SQLITE_OMIT_DEPRECATED
	SQLITE_OMIT_SHARED_CACHE
	SQLITE_OMIT_JSON
)
target_link_libraries(sqlcipher PRIVATE tomcrypt log)
reproducible_shared_library(sqlcipher)

set_source_files_properties(argon2_jni.c sqlcipher_jni.c PROPERTIES COMPILE_OPTIONS "-Wall;-Wextra;-Werror")
