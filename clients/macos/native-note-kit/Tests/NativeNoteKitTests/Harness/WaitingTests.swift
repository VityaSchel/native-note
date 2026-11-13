import Foundation
import Synchronization
import Testing

@MainActor
struct WaitingTests {
	@Test func aStateThatIsNeverReachedIsAFailureNotASilentReturn() async {
		await withKnownIssue {
			try await settle(within: .milliseconds(20)) { false }
		}
	}

	@Test func aStateReachedLaterEndsTheWaitWithoutAFailure() async throws {
		var polls = 0

		try await settle {
			polls += 1
			return polls == 3
		}

		#expect(polls == 3)
	}

	@Test func aWaitCancelledDuringAPollThrowsThereWithoutAFailure() async {
		var polls = 0
		let waiting = Task {
			try await settle {
				polls += 1
				if polls == 3 { withUnsafeCurrentTask { $0?.cancel() } }
				return false
			}
		}

		await #expect(throws: CancellationError.self) { try await waiting.value }
		#expect(polls == 3)
	}

	@Test func aCancelledWaitForAGateThrowsInsteadOfWaitingOutItsLimit() async {
		let waiting = Task { try await Gate().untilHolding() }
		waiting.cancel()

		await #expect(throws: CancellationError.self) { try await waiting.value }
	}

	@Test func aStateThatChangesWhileItShouldStayIsAFailure() async {
		var polls = 0

		await withKnownIssue {
			await staysTrue {
				polls += 1
				return polls < 5
			}
		}
		await staysTrue(for: 100) { true }

		#expect(polls == 5)
	}
}

@Suite(.scratch)
struct ScratchTests {
	@Test func aDirectoryMadeInATestIsRemovedWhenTheTestEnds() async throws {
		let made = Mutex<URL?>(nil)

		try await Scratch().provideScope(for: try #require(Test.current), testCase: Test.Case.current) {
			let directory = temporaryDirectory()
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
			try Data("left behind".utf8).write(to: directory.appending(path: "note"))
			made.withLock { $0 = directory }
		}

		let directory = try #require(made.withLock { $0 })
		#expect(!FileManager.default.fileExists(atPath: directory.path))
	}

	@Test func aDirectoryMadeOutsideAScratchTestIsAFailure() {
		Scratch.$directories.withValue(nil) {
			withKnownIssue {
				_ = temporaryDirectory()
			}
		}
	}
}
