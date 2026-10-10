import Foundation
import Testing

struct BuildScriptTests {
	private let buildScript = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../build.sh").standardized

	@Test func theBuildScriptPrintsOnlyTheHarnessPath() throws {
		let directory = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let tools = directory.appending(path: "tools")
		let products = directory.appending(path: "products")
		try FileManager.default.createDirectory(at: products.appending(path: "SQLCipher.framework"), withIntermediateDirectories: true)
		for product in ["power-loss", "power-loss-agent", "power-loss-flush-probe", "NativeNoteTypist"] {
			try Data().write(to: products.appending(path: product))
		}
		try stub("swift", in: tools, #"case " $* " in *" --show-bin-path "*) echo "$PRODUCTS" ;; *) echo "Building for production..."; echo "Build complete!" ;; esac"#)
		try stub("codesign", in: tools, #"echo "replacing existing signature" >&2"#)
		let output = Pipe()
		let process = Process()
		process.executableURL = URL(filePath: "/bin/bash")
		process.arguments = [buildScript.path]
		process.environment = ["PATH": "\(tools.path):/usr/bin:/bin", "PRODUCTS": products.path, "HOME": directory.path]
		process.standardOutput = output
		process.standardError = FileHandle.nullDevice

		try process.run()
		let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
		process.waitUntilExit()

		#expect(process.terminationStatus == 0)
		#expect(printed == products.appending(path: "power-loss").path + "\n")
		for item in ["power-loss-agent", "power-loss-flush-probe", "NativeNoteTypist", "setup.sh", "allow-agent.sh", "install-agent.sh", "start-agent.sh", "dev.hloth.devtools.native-note-power-loss-test.plist"] {
			#expect(FileManager.default.fileExists(atPath: products.appending(path: "guest/\(item)").path), "\(item)")
		}
	}
}
