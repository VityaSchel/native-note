// swift-tools-version: 6.2
import PackageDescription

let upcomingFeatures: [SwiftSetting] = [
	.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
	.enableUpcomingFeature("InferIsolatedConformances"),
	.enableUpcomingFeature("MemberImportVisibility"),
]

let kit = Target.Dependency.product(name: "NativeNoteKit", package: "native-note-kit")
let powerLossKit = Target.Dependency.product(name: "PowerLossKit", package: "macos-power-loss")

let package = Package(
	name: "NativeNoteTypist",
	platforms: [.macOS(.v26)],
	dependencies: [
		.package(path: "../../../clients/macos/native-note-kit"),
		.package(path: ".."),
	],
	targets: [
		.executableTarget(
			name: "NativeNoteTypist",
			dependencies: [kit],
			swiftSettings: [.defaultIsolation(MainActor.self)] + upcomingFeatures
		),
		.testTarget(
			name: "NativeNoteTypistTests",
			dependencies: ["NativeNoteTypist", powerLossKit, kit],
			swiftSettings: upcomingFeatures
		),
	]
)
