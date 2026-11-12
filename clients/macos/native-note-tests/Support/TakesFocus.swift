import Testing

struct TakesFocus: SuiteTrait, TestTrait, TestScoping {
	@MainActor private static var held = false
	@MainActor private static var waiting: [CheckedContinuation<Void, Never>] = []

	var isRecursive: Bool { true }

	func provideScope(for test: Test, testCase: Test.Case?, performing function: @concurrent @Sendable () async throws -> Void) async throws {
		guard testCase != nil else { return try await function() }
		await Self.take()
		do {
			try await function()
		} catch {
			await Self.give()
			throw error
		}
		await Self.give()
	}

	@MainActor private static func take() async {
		guard held else {
			held = true
			return
		}
		await withCheckedContinuation { waiting.append($0) }
	}

	@MainActor private static func give() {
		guard !waiting.isEmpty else {
			held = false
			return
		}
		waiting.removeFirst().resume()
	}
}

extension Trait where Self == TakesFocus {
	static var takesFocus: Self { TakesFocus() }
}
