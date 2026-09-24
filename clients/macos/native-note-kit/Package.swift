// swift-tools-version: 6.2
import PackageDescription

let upcomingFeatures: [SwiftSetting] = [
	.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
	.enableUpcomingFeature("InferIsolatedConformances"),
	.enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
	name: "NativeNoteKit",
	platforms: [.macOS(.v26)],
	products: [.library(name: "NativeNoteKit", targets: ["NativeNoteKit"])],
	dependencies: [
		.package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", revision: "205df55271aa1ba512a9bfe3fd1813bc9ac52a19"),
		.package(url: "https://github.com/P-H-C/phc-winner-argon2.git", revision: "f57e61e19229e23c4445b85494dbf7c07de721cb"),
	],
	targets: [
		.target(
			name: "NativeNoteKit",
			dependencies: [
				.product(name: "SQLCipher", package: "SQLCipher.swift"),
				.product(name: "argon2", package: "phc-winner-argon2"),
			],
			swiftSettings: [.defaultIsolation(MainActor.self)] + upcomingFeatures
		),
		.testTarget(
			name: "NativeNoteKitTests",
			dependencies: ["NativeNoteKit"],
			resources: [.copy("vectors")],
			swiftSettings: upcomingFeatures
		),
	]
)
