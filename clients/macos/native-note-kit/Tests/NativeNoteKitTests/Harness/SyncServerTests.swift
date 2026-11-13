import Foundation
import Synchronization
import Testing

@Suite(.scratch, .syncServer)
struct SyncServerTests {
	@Test func aFinishedBuildLeavesNoLogBehind() {
		#expect(!FileManager.default.fileExists(atPath: SyncServer.buildLog.path))
	}

	@Test func aServerStillHeldWhenItsTestEndsIsStopped() async throws {
		let held = Mutex<SyncServer?>(nil)

		try await BuildsSyncServer().provideScope(for: try #require(Test.current), testCase: Test.Case.current) {
			let server = try SyncServer()
			held.withLock { $0 = server }
		}

		let server = try #require(held.withLock { $0 })
		#expect(!server.isRunning)
	}
}
