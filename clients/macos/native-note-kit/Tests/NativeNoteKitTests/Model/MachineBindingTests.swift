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

		let record = try #require(try FileUnlockRecordStore(directory: directory).read())

		#expect((record.enclaveKey != nil) == MachineKey.isAvailable)
	}
}
