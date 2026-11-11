// swift-tools-version: 6.2
import PackageDescription

let upcomingFeatures: [SwiftSetting] = [
	.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
	.enableUpcomingFeature("InferIsolatedConformances"),
	.enableUpcomingFeature("MemberImportVisibility"),
]

let prebuiltSQLCipherDefaults: [CSetting] = [
	.define("SQLITE_HAS_CODEC"),
	.define("SQLCIPHER_CRYPTO_CC"),
	.define("SQLITE_EXTRA_INIT", to: "sqlcipher_extra_init"),
	.define("SQLITE_EXTRA_SHUTDOWN", to: "sqlcipher_extra_shutdown"),
	.define("SQLITE_THREADSAFE", to: "1"),
	.define("SQLITE_TEMP_STORE", to: "2"),
	.define("SQLITE_USE_URI", to: "1"),
	.define("SQLITE_DEFAULT_WAL_SYNCHRONOUS", to: "1"),
	.define("SQLITE_DEFAULT_JOURNAL_SIZE_LIMIT", to: "1048576"),
	.define("SQLITE_MAX_VARIABLE_NUMBER", to: "99999"),
	.define("SQLITE_ENABLE_MEMORY_MANAGEMENT"),
	.define("SQLITE_ENABLE_FTS5"),
]

let unusedSQLiteFeatures: [CSetting] = [
	.define("SQLITE_OMIT_LOAD_EXTENSION"),
	.define("SQLITE_OMIT_DEPRECATED"),
	.define("SQLITE_OMIT_SHARED_CACHE"),
	.define("SQLITE_OMIT_JSON"),
]

let sqliteDefinesItsOwnAssertMinAndMax = CSetting.unsafeFlags(["-fno-modules"])
let amalgamationWarningsOff = CSetting.unsafeFlags(["-Wno-shorten-64-to-32"])
let sqlcipherSettings = prebuiltSQLCipherDefaults + unusedSQLiteFeatures + [sqliteDefinesItsOwnAssertMinAndMax, amalgamationWarningsOff]

let package = Package(
	name: "NativeNoteKit",
	platforms: [.macOS(.v26)],
	products: [.library(name: "NativeNoteKit", targets: ["NativeNoteKit"])],
	dependencies: [
		.package(url: "https://github.com/P-H-C/phc-winner-argon2.git", revision: "f57e61e19229e23c4445b85494dbf7c07de721cb"),
	],
	targets: [
		.target(
			name: "SQLCipher",
			cSettings: sqlcipherSettings,
			linkerSettings: [.linkedFramework("Security"), .linkedFramework("CoreFoundation")]
		),
		.target(
			name: "NativeNoteKit",
			dependencies: [
				"SQLCipher",
				.product(name: "argon2", package: "phc-winner-argon2"),
			],
			resources: [.copy("Resources/english.txt")],
			swiftSettings: [.defaultIsolation(MainActor.self)] + upcomingFeatures
		),
		.executableTarget(
			name: "NativeNoteTypist",
			dependencies: ["NativeNoteKit"],
			swiftSettings: [.defaultIsolation(MainActor.self)] + upcomingFeatures
		),
		.testTarget(
			name: "NativeNoteKitTests",
			dependencies: ["NativeNoteKit", "NativeNoteTypist"],
			resources: [.copy("vectors"), .copy("fixtures")],
			swiftSettings: upcomingFeatures
		),
	]
)
