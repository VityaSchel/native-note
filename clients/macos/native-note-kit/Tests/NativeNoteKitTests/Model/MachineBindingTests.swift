import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.timeLimit(.minutes(1)))
struct MachineBindingTests {
	private func setUp(_ model: AppModel, in directory: URL) async throws -> UnlockParameters {
		model.start()
		await model.submit(password: workspacePassword)
		try #require(model.phase == .unlocked)
		await model.lock()
		return try AppLock.read(from: AppLock.currentFile(in: directory))
	}

	@Test func aLibraryBindsToThisMacWheneverItHasASecureEnclave() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		let parameters = try await setUp(AppModel(libraryAt: directory, keyStore: FakeKeyStore()), in: directory)

		#expect((parameters.enclaveKey != nil) == MachineKey.isAvailable)
	}

	@Test func aLibraryAskedNotToBindNeedsNoSecureEnclaveAndStillOpens() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		let parameters = try await setUp(AppModel(libraryAt: directory, keyStore: FakeKeyStore(), bindsToThisMac: false), in: directory)

		#expect(parameters.enclaveKey == nil)
		let relaunched = AppModel(libraryAt: directory, keyStore: FakeKeyStore())
		relaunched.start()
		await relaunched.submit(password: workspacePassword)
		#expect(relaunched.phase == .unlocked)
		await relaunched.lock()
	}
}
