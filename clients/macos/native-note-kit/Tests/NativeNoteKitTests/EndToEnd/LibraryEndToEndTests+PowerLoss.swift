import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

private struct VerifierReport: Decodable {
	let phase: String
	let failure: String?
	let integrity: String?
	let notes: Int
	let body: String?
	let walCheckpoints: Int?
}

private struct Acknowledgement {
	let sequence: Int
	let length: Int
	let digest: String

	init?(_ line: String) {
		let fields = line.split(separator: " ")
		guard fields.count == 4, fields[0] == "ack", let sequence = Int(fields[1]), let length = Int(fields[2]) else { return nil }
		self.sequence = sequence
		self.length = length
		digest = String(fields[3])
	}
}

extension LibraryEndToEndTests {
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

	private func digest(_ text: String) -> String {
		SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
	}

	@Test func theVerifierFindsEveryAcknowledgedSaveAfterTheTypistStopsAbruptly() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		let prepared = try await runTypist(["prepare", directory.path, workspacePassword])
		#expect(prepared.status == 0)
		#expect(prepared.lines == ["prepared 1"])

		let typing = try await runTypist(["acknowledge", directory.path, workspacePassword, "4"])
		#expect(typing.status == 0)
		#expect(typing.lines.first == "start 0")
		let acknowledgements = typing.lines.compactMap(Acknowledgement.init)
		#expect(acknowledgements.map(\.sequence) == [1, 2, 3, 4])
		#expect(acknowledgements.map(\.length) == acknowledgements.map(\.length).sorted())
		for acknowledgement in acknowledgements {
			#expect(acknowledgement.digest == digest(typed(acknowledgement.length)))
		}

		let report = try await verify(directory)
		let body = try #require(report.body)
		#expect(report.phase == "unlocked")
		#expect(report.integrity == "ok")
		#expect(report.notes == 1)
		#expect(report.walCheckpoints == 0)
		#expect(body == typed(body.count))
		#expect(body.count >= acknowledgements.last?.length ?? .max)
	}

	@Test func theControlTypistAcknowledgesTextTheVerifierCannotFind() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		#expect(try await runTypist(["prepare", directory.path, workspacePassword]).status == 0)

		let typing = try await runTypist(["acknowledge-before-saving", directory.path, workspacePassword, "3"])
		let acknowledgements = typing.lines.compactMap(Acknowledgement.init)
		#expect(typing.status == 0)
		#expect(acknowledgements.map(\.length) == [1, 2, 3])
		for acknowledgement in acknowledgements {
			#expect(acknowledgement.digest == digest(typed(acknowledgement.length)))
		}

		let report = try await verify(directory)
		#expect(report.phase == "unlocked")
		#expect(report.integrity == "ok")
		#expect(try #require(report.body).count < 3)
	}

	@Test func theVerifierReportsALibraryThatDoesNotUnlock() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		try AppLock.write(.fast, to: AppLock.currentFile(in: directory))
		try await NoteStore.create(url: AppLock.databaseFile(in: directory), key: workspaceKey()).close()

		let report = try await verify(directory, password: "wrong horse")

		#expect(report.phase == "locked")
		#expect(report.failure == "wrongPassword")
		#expect(report.integrity == nil)
	}

	@Test func theVerifierLeavesAMissingLibraryUnset() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		let report = try await verify(directory)

		#expect(report.phase == "needsSetup")
		#expect(report.walCheckpoints == nil)
		#expect(AppLock.parameterFiles(in: directory).isEmpty)
	}
}
