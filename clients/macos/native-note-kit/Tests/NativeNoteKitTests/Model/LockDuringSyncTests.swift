import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.timeLimit(.minutes(1)))
struct LockDuringSyncTests {
	private final class Hanging: SyncTransport, @unchecked Sendable {
		private let lock = NSLock()
		private var inFlight: CheckedContinuation<Void, Never>?
		private var posted = false
		private(set) var cancelled = false
		private(set) var unwound = false
		private(set) var libraryOpenWhenUnwound = false
		weak var store: NoteStore?

		func post(_ body: Data) async throws -> Data {
			lock.withLock {
				posted = true
				inFlight?.resume()
				inFlight = nil
			}
			do {
				try await Task.sleep(for: .seconds(600))
			} catch {
				lock.withLock { cancelled = true }
				await withCheckedContinuation { done in DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { done.resume() } }
				let open = (try? await store?.since()) != nil
				lock.withLock {
					unwound = true
					libraryOpenWhenUnwound = open
				}
				throw error
			}
			return Data()
		}

		func requestSent() async {
			await withCheckedContinuation { continuation in
				lock.withLock { posted ? continuation.resume() : (inFlight = continuation) }
			}
		}
	}

	@Test func lockingCancelsASyncInFlightBeforeTheLibraryCloses() async throws {
		let transport = Hanging()
		let (model, _) = try await unlockedModel { AppModel(directory: $0, makeTransport: { _ in transport }, syncDelay: .seconds(3600)) }
		try await fill(model, with: ["waiting to push"])
		let store = try #require(model.store)
		transport.store = store
		try await store.enableSync(SyncSettings(server: URL(string: "http://notes.example")!, apiKey: SymmetricKey(size: .bits256), contentKey: SymmetricKey(size: .bits256)), pin: 1)
		await model.startSync(store)
		await transport.requestSent()

		let started = ContinuousClock.now
		await model.lock()

		#expect(ContinuousClock.now - started < .seconds(10))
		#expect(transport.cancelled && transport.unwound && transport.libraryOpenWhenUnwound)
		#expect(model.engine == nil && model.syncLoop == nil)
		#expect(model.phase == .locked)
	}
}
