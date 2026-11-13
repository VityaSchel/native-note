import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.scratch, .timeLimit(.minutes(1)))
struct MachineBindingTests {
	@Test func aLibraryBindsToThisMacWheneverItHasASecureEnclave() async throws {
		let directory = temporaryDirectory()
		let model = AppModel(directory: directory, keyStore: FakeKeyStore())
		model.start()
		await model.submit(password: workspacePassword)
		try #require(model.phase == .unlocked)
		await model.lock()

		let parameters = try AppLock.read(from: AppLock.currentFile(in: directory))

		#expect((parameters.enclaveKey != nil) == MachineKey.isAvailable)
	}
}
