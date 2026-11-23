// swift-tools-version: 6.2
import PackageDescription

let upcomingFeatures: [SwiftSetting] = [
	.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
	.enableUpcomingFeature("InferIsolatedConformances"),
	.enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
	name: "VoiceOverRun",
	platforms: [.macOS(.v26)],
	products: [
		.executable(name: "voiceover-run", targets: ["VoiceOverRun"]),
	],
	targets: [
		.target(name: "VoiceOverRunKit", swiftSettings: [.defaultIsolation(MainActor.self)] + upcomingFeatures),
		.executableTarget(
			name: "VoiceOverRun",
			dependencies: ["VoiceOverRunKit"],
			swiftSettings: [.defaultIsolation(MainActor.self)] + upcomingFeatures
		),
		.testTarget(
			name: "VoiceOverRunKitTests",
			dependencies: ["VoiceOverRunKit"],
			swiftSettings: [.defaultIsolation(MainActor.self)] + upcomingFeatures
		),
	]
)
