import Foundation
import Synchronization
import Testing

struct Scratch: SuiteTrait, TestTrait, TestScoping {
	final class Directories: Sendable {
		private let made = Mutex<[URL]>([])

		func add(_ directory: URL) {
			made.withLock { $0.append(directory) }
		}

		func removeAll() {
			for directory in made.withLock({ $0 }) {
				try? FileManager.default.removeItem(at: directory)
			}
		}
	}

	@TaskLocal static var directories: Directories?

	var isRecursive: Bool { true }

	func provideScope(for test: Test, testCase: Test.Case?, performing function: @concurrent @Sendable () async throws -> Void) async throws {
		guard testCase != nil else { return try await function() }
		let directories = Directories()
		defer { directories.removeAll() }
		try await Self.$directories.withValue(directories) { try await function() }
	}
}

extension Trait where Self == Scratch {
	static var scratch: Self { Scratch() }
}

func temporaryDirectory(sourceLocation: SourceLocation = #_sourceLocation) -> URL {
	let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
	if let directories = Scratch.directories {
		directories.add(directory)
	} else {
		Issue.record("A temporary directory needs the .scratch trait on its test or suite to be removed.", sourceLocation: sourceLocation)
	}
	return directory
}
