import Foundation
import Testing

struct BuildScriptTests {
	private let harness = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../..").standardized

	private struct Build {
		let status: Int32
		let printed: String
		let products: URL
		let typistProducts: URL
		let calls: [String]
	}

	private func build(in directory: URL) throws -> Build {
		let manager = FileManager.default
		let checkout = directory.appending(path: "checkout/devtools/macos-power-loss")
		let tools = directory.appending(path: "tools")
		let products = directory.appending(path: "products")
		let typistProducts = directory.appending(path: "typist-products")
		let calls = directory.appending(path: "calls")
		try manager.createDirectory(at: checkout, withIntermediateDirectories: true)
		for item in ["build.sh", "guest"] {
			try manager.copyItem(at: harness.appending(path: item), to: checkout.appending(path: item))
		}
		try stub("sqlcipher-amalgamation.sh", in: directory.appending(path: "checkout/clients/macos/native-note-kit/Scripts"), #"echo "sqlcipher-amalgamation.sh" >>"$CALLS""#)
		try manager.createDirectory(at: products.appending(path: "guest"), withIntermediateDirectories: true)
		try manager.createDirectory(at: typistProducts, withIntermediateDirectories: true)
		try Data().write(to: products.appending(path: "guest/left-from-an-older-build"))
		for product in ["power-loss", "power-loss-agent"] {
			try Data().write(to: products.appending(path: product))
		}
		try Data("left from an older build".utf8).write(to: products.appending(path: "NativeNoteTypist"))
		try Data("built in the typist package".utf8).write(to: typistProducts.appending(path: "NativeNoteTypist"))
		try stub("swift", in: tools, #"""
			echo "swift $*" >>"$CALLS"
			case " $* " in
			*" --package-path typist --show-bin-path "*) echo "$TYPIST_PRODUCTS" ;;
			*" --show-bin-path "*) echo "$PRODUCTS" ;;
			*) echo "Building for production..."; echo "Build complete!" ;;
			esac
			"""#)
		try stub("codesign", in: tools, #"echo "replacing existing signature" >&2"#)
		let output = Pipe()
		let process = Process()
		process.executableURL = URL(filePath: "/bin/bash")
		process.arguments = [checkout.appending(path: "build.sh").path]
		process.environment = ["PATH": "\(tools.path):/usr/bin:/bin", "PRODUCTS": products.path, "TYPIST_PRODUCTS": typistProducts.path, "CALLS": calls.path, "HOME": directory.path]
		process.standardOutput = output
		process.standardError = FileHandle.nullDevice

		try process.run()
		let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
		process.waitUntilExit()
		let made = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").map(String.init)
		return Build(status: process.terminationStatus, printed: printed, products: products, typistProducts: typistProducts, calls: made)
	}

	@Test func theBuildScriptPrintsOnlyTheHarnessPathAndStagesExactlyTheGuestKit() throws {
		let directory = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		let built = try build(in: directory)

		#expect(built.status == 0)
		#expect(built.printed == built.products.appending(path: "power-loss").path + "\n")
		let staged = try FileManager.default.contentsOfDirectory(atPath: built.products.appending(path: "guest").path).sorted()
		#expect(staged == ["NativeNoteTypist", "dev.hloth.devtools.native-note-power-loss-test.plist", "install-agent.sh", "power-loss-agent", "setup.sh", "start-agent.sh"])
	}

	@Test func theStagedTypistIsTheOneBuiltInItsOwnPackage() throws {
		let directory = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		let built = try build(in: directory)

		#expect(built.status == 0)
		let staged = try Data(contentsOf: built.products.appending(path: "guest/NativeNoteTypist"))
		#expect(staged == (try Data(contentsOf: built.typistProducts.appending(path: "NativeNoteTypist"))))
	}

	@Test func theHarnessIsBuiltBeforeTheKitSourceIsGeneratedAndOnlyTheTypistAgainstATestableKit() throws {
		let directory = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		let built = try build(in: directory)

		#expect(built.status == 0)
		#expect(built.calls == [
			"swift build -c release --product power-loss",
			"swift build -c release --product power-loss-agent",
			"sqlcipher-amalgamation.sh",
			"swift build -c release --package-path typist --product NativeNoteTypist -Xswiftc -enable-testing",
			"swift build -c release --show-bin-path",
			"swift build -c release --package-path typist --show-bin-path",
		])
	}

	@Test func theHarnessPackageDependsOnNoOtherPackageAndLeavesTheKitToTheTypistPackage() throws {
		let harnessManifest = try String(contentsOf: harness.appending(path: "Package.swift"), encoding: .utf8)
		let harnessTargets = try FileManager.default.contentsOfDirectory(at: harness.appending(path: "Sources"), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)

		#expect(!harnessManifest.contains(".package("))
		#expect(Set(harnessTargets.map(\.lastPathComponent)) == ["PowerLoss", "PowerLossAgent", "PowerLossKit"])
		let typistManifest = try String(contentsOf: harness.appending(path: "typist/Package.swift"), encoding: .utf8)
		#expect(typistManifest.contains(#".package(path: "../../../clients/macos/native-note-kit")"#))
	}
}
