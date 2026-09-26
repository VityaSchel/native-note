import AppKit
import Security
import Testing

@testable import NativeNote
@testable import NativeNoteKit

@MainActor
private final class Calls {
	var passwords: [String] = []
	var replies: [AppModel.Failure?] = []
	var done = 0
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct TurnOnTouchIDViewTests {
	private let alarm = Alarm()

	private func offscreen(_ calls: Calls, turnOn: @escaping (String) async -> AppModel.Failure?) -> OffscreenWindow<TurnOnTouchIDView> {
		OffscreenWindow(
			TurnOnTouchIDView(turnOn: { password in
				calls.passwords.append(password)
				let reply = await turnOn(password)
				calls.replies.append(reply)
				return reply
			}, done: { calls.done += 1 }),
			width: 360,
			height: 160
		)
	}

	private func library(_ keys: FakeKeyStore) async throws -> (AppModel, URL) {
		try await unlockedModel { [alarm] directory in
			AppModel(directory: directory, scheduler: SaveScheduler(sleep: alarm.sleep), keyStore: keys)
		}
	}

	private func type(_ text: String, in offscreen: OffscreenWindow<TurnOnTouchIDView>) throws -> NSSecureTextField {
		let field = try #require(offscreen.views(of: NSSecureTextField.self).first { $0.placeholderString == "Password" })
		try #require(offscreen.window.makeFirstResponder(field))
		try #require(field.currentEditor()).insertText(text)
		offscreen.pump()
		return field
	}

	@discardableResult
	private func submit(_ text: String, in offscreen: OffscreenWindow<TurnOnTouchIDView>) throws -> NSSecureTextField {
		let field = try type(text, in: offscreen)
		try #require(field.currentEditor()).insertNewline(nil)
		return field
	}

	private func pressEscape(in offscreen: OffscreenWindow<TurnOnTouchIDView>) throws -> Bool {
		let escape = try #require(
			NSEvent.keyEvent(
				with: .keyDown,
				location: .zero,
				modifierFlags: [],
				timestamp: 0,
				windowNumber: offscreen.window.windowNumber,
				context: nil,
				characters: "\u{1b}",
				charactersIgnoringModifiers: "\u{1b}",
				isARepeat: false,
				keyCode: 53
			)
		)
		let handled = offscreen.host.performKeyEquivalent(with: escape)
		offscreen.pump()
		return handled
	}

	private func isWorking(_ offscreen: OffscreenWindow<TurnOnTouchIDView>) -> Bool {
		!offscreen.views(of: NSProgressIndicator.self).isEmpty
	}

	@Test func returnSendsThePasswordOnceAndCloses() async throws {
		let calls = Calls()
		let offscreen = offscreen(calls) { _ in nil }
		defer { offscreen.close() }

		try submit("correct horse", in: offscreen)
		await offscreen.pump { calls.done > 0 }

		#expect(calls.passwords == ["correct horse"])
		#expect(calls.done == 1)
	}

	@Test func anEmptyPasswordSendsNothing() async throws {
		let calls = Calls()
		let offscreen = offscreen(calls) { _ in nil }
		defer { offscreen.close() }

		try submit("", in: offscreen)
		await offscreen.pump(turns: 20) { false }

		#expect(calls.passwords.isEmpty)
		#expect(calls.done == 0)
	}

	@Test func theRightPasswordTurnsTouchIDOnAndCloses() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let calls = Calls()
		let offscreen = offscreen(calls, turnOn: model.enableBiometricUnlock(password:))
		defer { offscreen.close() }
		#expect(!isWorking(offscreen))

		try submit(workspacePassword, in: offscreen)
		await offscreen.pump(turns: 4_000) { calls.done > 0 }

		#expect(calls.done == 1)
		#expect(calls.replies == [nil])
		#expect(model.isBiometricUnlockEnabled)
		#expect(keys.reasons == ["turn on Touch ID unlock"])
		#expect(keys.storedKey == (try await workspaceKey()))
		#expect(model.failure == nil)
	}

	@Test func aWrongPasswordStaysOpenWithTheFieldCleared() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let calls = Calls()
		let offscreen = offscreen(calls, turnOn: model.enableBiometricUnlock(password:))
		defer { offscreen.close() }

		let field = try submit("a guess", in: offscreen)
		await offscreen.pump(turns: 4_000) { !calls.replies.isEmpty && field.stringValue.isEmpty && !isWorking(offscreen) }

		#expect(calls.replies == [.wrongPassword])
		#expect(field.stringValue.isEmpty)
		#expect(!isWorking(offscreen))
		#expect(calls.done == 0)
		#expect(!model.isBiometricUnlockEnabled)
		#expect(keys.storedKey == nil)
		#expect(keys.reasons.isEmpty)
	}

	@Test func escapeCancelsWithoutTurningAnythingOn() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let calls = Calls()
		let offscreen = offscreen(calls, turnOn: model.enableBiometricUnlock(password:))
		defer { offscreen.close() }
		_ = try type(workspacePassword, in: offscreen)

		#expect(try pressEscape(in: offscreen))
		await offscreen.pump { calls.done > 0 }

		#expect(calls.done == 1)
		#expect(calls.passwords.isEmpty)
		#expect(!model.isBiometricUnlockEnabled)
		#expect(keys.storedKey == nil)
		#expect(keys.reasons.isEmpty)
	}

	@Test func cancellingTouchIDClosesWithItOff() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .cancel)
		let calls = Calls()
		let offscreen = offscreen(calls, turnOn: model.enableBiometricUnlock(password:))
		defer { offscreen.close() }

		try submit(workspacePassword, in: offscreen)
		await offscreen.pump(turns: 4_000) { calls.done > 0 }

		#expect(calls.done == 1)
		#expect(calls.replies == [nil])
		#expect(keys.reasons == ["turn on Touch ID unlock"])
		#expect(!model.isBiometricUnlockEnabled)
		#expect(keys.storedKey == nil)
	}

	@Test func aKeychainFailureStaysOpenWithThePassword() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.failWrites()
		let calls = Calls()
		let offscreen = offscreen(calls, turnOn: model.enableBiometricUnlock(password:))
		defer { offscreen.close() }

		let field = try submit(workspacePassword, in: offscreen)
		await offscreen.pump(turns: 4_000) { !calls.replies.isEmpty && !isWorking(offscreen) }

		#expect(calls.replies == [.unexpected("Touch ID unlock could not be turned on. \(KeychainFailure(status: errSecNotAvailable).message)")])
		#expect(field.stringValue == workspacePassword)
		#expect(calls.done == 0)
		#expect(!model.isBiometricUnlockEnabled)
		#expect(model.failure == nil)
	}

	@Test func whileTouchIDAsksTheSheetWaitsAndCannotBeCancelled() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let (answer, answered) = AsyncStream<Void>.makeStream()
		keys.whileLoading {
			for await _ in answer { break }
		}
		let calls = Calls()
		let offscreen = offscreen(calls, turnOn: model.enableBiometricUnlock(password:))
		defer { offscreen.close() }

		try submit(workspacePassword, in: offscreen)
		await offscreen.pump(turns: 4_000) { !keys.reasons.isEmpty && isWorking(offscreen) }

		#expect(isWorking(offscreen))
		_ = try pressEscape(in: offscreen)
		await offscreen.pump(turns: 20) { false }
		#expect(calls.done == 0)

		answered.yield()
		await offscreen.pump { calls.done > 0 }
		#expect(calls.done == 1)
		#expect(model.isBiometricUnlockEnabled)
	}

	@Test func lockingWhileTouchIDAsksLeavesItOff() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let (answer, answered) = AsyncStream<Void>.makeStream()
		keys.whileLoading {
			for await _ in answer { break }
		}
		let calls = Calls()
		let offscreen = offscreen(calls, turnOn: model.enableBiometricUnlock(password:))
		defer { offscreen.close() }

		try submit(workspacePassword, in: offscreen)
		await offscreen.pump(turns: 4_000) { !keys.reasons.isEmpty }
		await model.lock()
		answered.yield()
		await offscreen.pump { calls.done > 0 }

		#expect(calls.replies == [nil])
		#expect(keys.storedKey == nil)
		#expect(!model.isBiometricUnlockEnabled)
		#expect(!model.canUnlockWithBiometrics)
	}
}
