import Foundation
import Testing

@testable import NativeNoteKit

struct AppLockTests {
	@Test func writesPrivatelyAndReadsBack() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = AppLock.currentFile(in: directory)

		try AppLock.write(.sample, to: url)

		let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
		let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
		#expect(fileMode?.int16Value == 0o600)
		#expect(directoryMode?.int16Value == 0o700)
		#expect(try AppLock.read(from: url) == .sample)
	}

	@Test func refusesParametersFromAFutureVersion() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		var future = UnlockParameters.sample
		future.version = 2
		let url = AppLock.currentFile(in: directory)

		try AppLock.write(future, to: url)

		#expect(throws: AppLock.Unreadable.unsupportedVersion(2)) { try AppLock.read(from: url) }
		#expect(AppLock.candidates(in: directory).isEmpty)
	}

	@Test func offersPendingParametersFirstButKeepsTheCurrentOneAsFallback() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		var next = UnlockParameters.sample
		next.localSalt = Data(repeating: 0x99, count: 16)

		try AppLock.write(.sample, to: AppLock.currentFile(in: directory))
		#expect(AppLock.candidates(in: directory).map(\.localSalt) == [UnlockParameters.sample.localSalt])

		try AppLock.write(next, to: AppLock.pendingRekeyFile(in: directory))
		#expect(
			AppLock.candidates(in: directory).map(\.localSalt)
				== [next.localSalt, UnlockParameters.sample.localSalt]
		)
	}

	@Test func promotingARekeyLeavesExactlyOneFile() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		var next = UnlockParameters.sample
		next.localSalt = Data(repeating: 0x99, count: 16)
		try AppLock.write(.sample, to: AppLock.currentFile(in: directory))
		try AppLock.write(next, to: AppLock.pendingRekeyFile(in: directory))

		try AppLock.promoteRekey(in: directory)

		#expect(AppLock.candidates(in: directory).map(\.localSalt) == [next.localSalt])
		#expect(!FileManager.default.fileExists(atPath: AppLock.pendingRekeyFile(in: directory).path))
		let mode = try FileManager.default.attributesOfItem(atPath: AppLock.currentFile(in: directory).path)[.posixPermissions] as? NSNumber
		#expect(mode?.int16Value == 0o600)
	}

	@Test func reportsNothingWhenTheAppHasNeverBeenSetUp() {
		#expect(AppLock.candidates(in: temporaryDirectory()).isEmpty)
	}
}
