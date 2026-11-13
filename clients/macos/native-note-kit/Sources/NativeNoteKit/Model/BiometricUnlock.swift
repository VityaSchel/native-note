import AppKit
import CryptoKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import Observation

@Observable final class BiometricUnlock {
	typealias State = AppModel.TouchID

	private(set) var state = State.hidden
	private(set) var isEnabled = false
	private(set) var shake = AppModel.Shake()
	private(set) var isCheckingPassword = false
	private(set) var isOpening = false
	var libraryIsLocked = false

	private let keyStore: any UnlockKeyStore
	private let shakeTimer: SaveScheduler.Sleep
	private var biometrics = BiometricAvailability.unavailable
	private var isActive = false
	private var stop: State.Stop?
	private var evaluating: LAContext?
	private var confirmation: CheckedContinuation<StoredKeyRead, Error>?

	init(keyStore: any UnlockKeyStore, shakeTimer: @escaping SaveScheduler.Sleep) {
		self.keyStore = keyStore
		self.shakeTimer = shakeTimer
	}

	func refresh() {
		isEnabled = confirmation == nil && keyStore.hasKey()
		biometrics = keyStore.availability
		settle()
	}

	func reset() {
		stop = nil
		refresh()
	}

	func appBecameActive() {
		isActive = true
		refresh()
	}

	func appResignedActive() {
		isActive = false
		if stop == .cancel { stop = nil }
		settle()
	}

	func checkingPassword(_ checking: Bool) {
		isCheckingPassword = checking
		settle()
	}

	func tryAgain() {
		guard case .needsClick = state else { return }
		stop = nil
		settle()
	}

	func startShake() {
		guard !shake.isRunning else { return }
		shake.count += 1
		shake.isRunning = true
		settle()
		Task { [shakeTimer] in
			try? await shakeTimer(AppModel.Shake.duration)
			shake.isRunning = false
			settle()
		}
	}

	func turnOn(with key: SymmetricKey, while isStillCurrent: () -> Bool) async -> AppModel.Failure? {
		guard isStillCurrent() else {
			try? keyStore.delete()
			return nil
		}
		do {
			try keyStore.save(key)
			let read = try await touchToConfirm()
			guard case let .key(confirmed) = read else {
				try? keyStore.delete()
				switch read {
				case .lockedOut: return .unexpected("Touch ID unlock could not be turned on. Touch ID is locked.")
				case .unavailable: return .unexpected("Touch ID unlock could not be turned on. Touch ID is not available.")
				case .key, .missed, .cancelled: return nil
				}
			}
			guard isStillCurrent() else {
				try? keyStore.delete()
				return nil
			}
			guard confirmed == key else {
				try? keyStore.delete()
				return .unexpected("Touch ID unlock could not be turned on. Try again.")
			}
			return nil
		} catch {
			try? keyStore.delete()
			return .unexpected("Touch ID unlock could not be turned on. \(Self.reason(for: error))")
		}
	}

	func cancelTurningOn() {
		guard confirmation != nil else { return }
		try? keyStore.delete()
		finishConfirmation(.success(.cancelled))
	}

	func turnOff() -> AppModel.Failure? {
		defer { refresh() }
		do {
			try keyStore.delete()
			return nil
		} catch {
			return .unexpected("Touch ID unlock could not be turned off. \(Self.reason(for: error))")
		}
	}

	func listen(through glyph: LAAuthenticationView, open: (SymmetricKey) async -> Error?) async -> AppModel.Failure? {
		guard case let .listening(context) = state, glyph.context === context, glyph.window != nil, evaluating !== context else { return nil }
		evaluating = context
		let confirming = confirmation != nil
		let read: Result<StoredKeyRead, Error>
		do {
			read = .success(try await keyStore.read(through: context, reason: confirming ? "turn on Touch ID unlock" : "unlock your notes"))
		} catch {
			read = .failure(error)
		}
		if evaluating === context { evaluating = nil }
		guard state == .listening(context) else { return nil }
		guard confirming else { return await unlock(with: read, open: open) }
		confirm(with: read)
		return nil
	}

	private func unlock(with read: Result<StoredKeyRead, Error>, open: (SymmetricKey) async -> Error?) async -> AppModel.Failure? {
		switch read {
		case let .success(.key(key)):
			isOpening = true
			settle()
			let error = await open(key)
			isOpening = false
			guard let error else {
				settle()
				return nil
			}
			if case Unlock.Failure.storedKeyRejected = error {
				return forgetStoredKey(explaining: AppModel.Failure.reason(for: error))
			}
			waitForClick(after: .failure)
		case .success(.missed):
			if keyStore.availability == .lockedOut { biometrics = .lockedOut }
			startShake()
		case .success(.cancelled):
			waitForClick(after: .cancel)
		case .success(.lockedOut):
			biometrics = .lockedOut
			stop = nil
			settle()
		case .success(.unavailable):
			biometrics = .unavailable
			settle()
		case .failure:
			return forgetStoredKey(explaining: "Touch ID could not read the unlock key. Unlock with your password.")
		}
		return nil
	}

	private func confirm(with read: Result<StoredKeyRead, Error>) {
		switch read {
		case .success(.missed):
			waitForClick(after: .miss)
		case .success(.cancelled):
			waitForClick(after: .cancel)
		default:
			finishConfirmation(read)
		}
	}

	private func touchToConfirm() async throws -> StoredKeyRead {
		guard confirmation == nil else { return .cancelled }
		return try await withCheckedThrowingContinuation { continuation in
			confirmation = continuation
			stop = nil
			settle()
		}
	}

	private func finishConfirmation(_ read: Result<StoredKeyRead, Error>) {
		guard let confirmation else { return }
		self.confirmation = nil
		stop = nil
		settle()
		confirmation.resume(with: read)
	}

	private func waitForClick(after stop: State.Stop) {
		self.stop = stop
		settle()
	}

	private func forgetStoredKey(explaining message: String) -> AppModel.Failure {
		if (try? keyStore.delete()) == nil { stop = .failure }
		refresh()
		return .unexpected(message)
	}

	private func settle() {
		let next = nextState()
		guard next != state else { return }
		if case let .listening(context) = state { context.invalidate() }
		state = next
	}

	private func nextState() -> State {
		let confirming = confirmation != nil
		guard confirming || (libraryIsLocked && isEnabled && biometrics != .unavailable) else { return .hidden }
		if isOpening { return .working }
		if !confirming, biometrics == .lockedOut { return .lockedOut }
		if let stop { return .needsClick(after: stop) }
		if isCheckingPassword { return .paused(.checkingPassword) }
		if !confirming, shake.isRunning { return .paused(.shaking) }
		if !isActive { return .paused(.inBackground) }
		if case .listening = state { return state }
		return .listening(LAContext())
	}

	private static func reason(for error: Error) -> String {
		(error as? KeychainFailure)?.message ?? error.localizedDescription
	}
}
