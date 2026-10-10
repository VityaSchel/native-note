// swift-tools-version: 6.2
import PackageDescription

let upcomingFeatures: [SwiftSetting] = [
	.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
	.enableUpcomingFeature("InferIsolatedConformances"),
	.enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
	name: "PowerLoss",
	platforms: [.macOS(.v26)],
	products: [
		.executable(name: "power-loss", targets: ["PowerLoss"]),
		.executable(name: "power-loss-agent", targets: ["PowerLossAgent"]),
		.executable(name: "power-loss-flush-probe", targets: ["PowerLossFlushProbe"]),
	],
	targets: [
		.target(name: "PowerLossKit", swiftSettings: upcomingFeatures),
		.executableTarget(
			name: "PowerLoss",
			dependencies: ["PowerLossKit"],
			swiftSettings: [.defaultIsolation(MainActor.self)] + upcomingFeatures
		),
		.executableTarget(name: "PowerLossAgent", dependencies: ["PowerLossKit"], swiftSettings: upcomingFeatures),
		.executableTarget(name: "PowerLossFlushProbe", dependencies: ["PowerLossKit"], swiftSettings: upcomingFeatures),
		.testTarget(name: "PowerLossKitTests", dependencies: ["PowerLossKit"], swiftSettings: upcomingFeatures),
	]
)
