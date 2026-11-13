import Foundation
import PowerLossKit
import Testing

@testable import NativeNoteKit

private final class BuiltBesideTheTypist {}

@MainActor @Suite(.scratch, .serialized, .timeLimit(.minutes(10)))
struct TypistTests {
	func typist() throws -> URL {
		let built = sequence(first: Bundle(for: BuiltBesideTheTypist.self).bundleURL) { $0.pathComponents.count > 1 ? $0.deletingLastPathComponent() : nil }
			.map { $0.appending(path: "NativeNoteTypist") }
			.first { FileManager.default.isExecutableFile(atPath: $0.path) }
		return try #require(built, "NativeNoteTypist is built beside the test bundle")
	}

	private func runTypist(_ arguments: [String]) async throws -> (lines: [String], status: Int32) {
		let output = Pipe()
		let process = Process()
		process.executableURL = try typist()
		process.arguments = arguments
		process.standardOutput = output
		let exited = AsyncStream<Void> { continuation in
			process.terminationHandler = { _ in continuation.finish() }
		}
		try process.run()
		var lines: [String] = []
		for try await line in output.fileHandleForReading.bytes.lines {
			lines.append(line)
		}
		for await _ in exited {}
		return (lines, process.terminationStatus)
	}

	private func verify(_ directory: URL, password: String = workspacePassword) async throws -> VerifierReport {
		let verified = try await runTypist(["verify", directory.path, password])
		#expect(verified.status == 0)
		return try JSONDecoder().decode(VerifierReport.self, from: Data(try #require(verified.lines.last).utf8))
	}

	@Test func theVerifierFindsEveryAcknowledgedSaveAfterTheTypistStopsAbruptly() async throws {
		let directory = temporaryDirectory()

		let prepared = try await runTypist(["prepare", directory.path, workspacePassword])
		#expect(prepared.status == 0)
		#expect(prepared.lines == ["prepared 1"])

		let typing = try await runTypist(["acknowledge", directory.path, workspacePassword, "4"])
		#expect(typing.status == 0)
		#expect(typing.lines.first == "start 0")
		let log = TypingLog(typing.lines)
		#expect(log.unexpected.isEmpty)
		#expect(log.acknowledgements.map(\.sequence) == [1, 2, 3, 4])
		#expect(log.acknowledgements.map(\.length) == log.acknowledgements.map(\.length).sorted())
		for acknowledgement in log.acknowledgements {
			#expect(acknowledgement.digest == TypedStream.digest(length: acknowledgement.length))
		}

		let report = try await verify(directory)
		let body = try #require(report.body)
		#expect(report.phase == "unlocked")
		#expect(report.integrity == "ok")
		#expect(report.notes == 1)
		#expect(report.walCheckpoints == 0)
		#expect(body == TypedStream.text(length: body.count))
		#expect(body.count >= log.acknowledgements.last?.length ?? .max)
	}

	@Test func theControlTypistAcknowledgesTextTheVerifierCannotFind() async throws {
		let directory = temporaryDirectory()
		#expect(try await runTypist(["prepare", directory.path, workspacePassword]).status == 0)

		let typing = try await runTypist(["acknowledge-before-saving", directory.path, workspacePassword, "3"])
		let acknowledgements = TypingLog(typing.lines).acknowledgements
		#expect(typing.status == 0)
		#expect(acknowledgements.map(\.length) == [1, 2, 3])
		for acknowledgement in acknowledgements {
			#expect(acknowledgement.digest == TypedStream.digest(length: acknowledgement.length))
		}

		let report = try await verify(directory)
		#expect(report.phase == "unlocked")
		#expect(report.integrity == "ok")
		#expect(try #require(report.body).count < 3)
	}

	@Test func theVerifierReportsALibraryThatDoesNotUnlock() async throws {
		let directory = temporaryDirectory()
		try AppLock.write(.fast, to: AppLock.currentFile(in: directory))
		try await NoteStore.create(url: AppLock.databaseFile(in: directory), key: workspaceKey()).close()

		let report = try await verify(directory, password: "wrong horse")

		#expect(report.phase == "locked")
		#expect(report.failure == "wrongPassword")
		#expect(report.integrity == nil)
	}

	@Test func theVerifierLeavesAMissingLibraryUnset() async throws {
		let directory = temporaryDirectory()

		let report = try await verify(directory)

		#expect(report.phase == "needsSetup")
		#expect(report.walCheckpoints == nil)
		#expect(AppLock.parameterFiles(in: directory).isEmpty)
	}

	@Test func theTypistsLibraryIsNotBoundToThisMacAndStillOpens() async throws {
		let directory = temporaryDirectory()
		#expect(try await runTypist(["prepare", directory.path, workspacePassword]).status == 0)

		#expect(try AppLock.read(from: AppLock.currentFile(in: directory)).enclaveKey == nil)
		let relaunched = AppModel(directory: directory, keyStore: FakeKeyStore())
		relaunched.start()
		await relaunched.submit(password: workspacePassword)
		#expect(relaunched.phase == .unlocked)
		await relaunched.lock()
	}
}
