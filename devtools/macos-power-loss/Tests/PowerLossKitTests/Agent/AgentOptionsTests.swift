import Foundation
import Testing

@testable import PowerLossKit

struct AgentOptionsTests {
	private let workingDirectory = URL(filePath: "/private/var/root", directoryHint: .isDirectory)

	@Test func theKitFolderTheLauncherPassesIsUsed() throws {
		let options = try AgentOptions(["power-loss-agent", "--kit", "/private/var/native-note-power-loss/kit", "--stdio"], currentDirectory: workingDirectory)

		#expect(options.kit.path == "/private/var/native-note-power-loss/kit")
		#expect(options.stdio)
	}

	@Test func aRelativeKitFolderIsReadFromTheWorkingDirectory() throws {
		let options = try AgentOptions(["/usr/bin/true", "--kit", "../kit"], currentDirectory: workingDirectory)

		#expect(options.kit.path == "/private/var/kit")
		#expect(!options.stdio)
	}

	@Test func withoutAKitFolderTheAgentsOwnPathIsUsed() throws {
		let options = try AgentOptions(["/private/var/native-note-power-loss/kit/power-loss-agent"], currentDirectory: workingDirectory)

		#expect(options.kit.path == "/private/var/native-note-power-loss/kit")
	}

	@Test func aRelativeAgentPathIsReadFromTheWorkingDirectory() throws {
		let options = try AgentOptions(["../native-note-power-loss/kit/power-loss-agent", "--stdio"], currentDirectory: workingDirectory)

		#expect(options.kit.path == "/private/var/native-note-power-loss/kit")
		#expect(options.stdio)
	}

	@Test func aSymlinkedAgentFindsTheFolderItLinksInto() throws {
		let directory = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let kit = directory.appending(path: "kit")
		try FileManager.default.createDirectory(at: kit, withIntermediateDirectories: true)
		try Data().write(to: kit.appending(path: "power-loss-agent"))
		try FileManager.default.createSymbolicLink(at: directory.appending(path: "agent"), withDestinationURL: kit.appending(path: "power-loss-agent"))

		let options = try AgentOptions([directory.appending(path: "agent").path], currentDirectory: workingDirectory)

		#expect(options.kit.resolvingSymlinksInPath().path == kit.resolvingSymlinksInPath().path)
	}

	@Test(arguments: [
		(["power-loss-agent"], "cannot tell which folder holds the agent; pass --kit"),
		(["power-loss-agent", "--stdio"], "cannot tell which folder holds the agent; pass --kit"),
		(["/kit/power-loss-agent", "--kit"], "--kit needs a value"),
		(["/kit/power-loss-agent", "--serve"], "unknown option --serve"),
	])
	func badArgumentsAreExplained(_ arguments: [String], _ message: String) {
		#expect(throws: OptionError(message)) { try AgentOptions(arguments, currentDirectory: workingDirectory) }
	}
}
