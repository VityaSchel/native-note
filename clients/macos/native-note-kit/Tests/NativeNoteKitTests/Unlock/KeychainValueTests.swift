import CryptoKit
import Foundation
import LocalAuthentication
import Testing

@testable import NativeNoteKit

struct KeychainValueTests {
	@Test func theValueHandedToTheKeychainHoldsTheKeyAndIsWipedAfterwards() {
		let key = SymmetricKey(data: Data((0 ..< 32).map { UInt8($0 + 1) }))

		let (handed, seen) = KeychainUnlockKeyStore.withItemValue(of: key) { ($0, Data($0 as Data)) }

		#expect(seen == key.withUnsafeBytes { Data($0) })
		#expect(CFDataGetLength(handed) == 32)
		#expect((handed as Data).allSatisfy { $0 == 0 })
	}

	@Test func theKeychainsAnswerBecomesTheKeyItHolds() throws {
		let bytes = Data((0 ..< 32).map { UInt8(255 - $0) })

		#expect(try KeychainUnlockKeyStore.key(from: bytes as NSData) == SymmetricKey(data: bytes))
	}

	@Test func aKeychainAnswerThatIsNotDataIsRejected() {
		#expect(throws: KeychainFailure(status: errSecDecode)) {
			try KeychainUnlockKeyStore.key(from: "not a key" as NSString)
		}
		#expect(throws: KeychainFailure(status: errSecDecode)) {
			try KeychainUnlockKeyStore.key(from: nil)
		}
	}

	@Test func eachTouchIDAnswerBecomesWhatTheLockScreenShows() throws {
		let expected: [(LAError.Code, StoredKeyRead)] = [
			(.authenticationFailed, .missed),
			(.biometryLockout, .lockedOut),
			(.userCancel, .cancelled),
			(.appCancel, .cancelled),
			(.systemCancel, .cancelled),
			(.userFallback, .cancelled),
			(.invalidContext, .cancelled),
			(.notInteractive, .cancelled),
			(.invalidDimensions, .cancelled),
			(.biometryNotAvailable, .unavailable),
			(.biometryNotEnrolled, .unavailable),
			(.biometryNotPaired, .unavailable),
			(.biometryDisconnected, .unavailable),
			(.passcodeNotSet, .unavailable),
		]

		for (code, read) in expected {
			#expect(try KeychainUnlockKeyStore.outcome(ofEvaluation: LAError(code)) == read, "\(code)")
			#expect(try KeychainUnlockKeyStore.outcome(ofEvaluation: NSError(domain: LAErrorDomain, code: code.rawValue)) == read, "\(code)")
		}
	}

	@Test func aFailureFromOutsideTouchIDIsRaisedAsItIs() {
		#expect(throws: KeychainFailure(status: errSecParam)) {
			try KeychainUnlockKeyStore.outcome(ofEvaluation: KeychainFailure(status: errSecParam))
		}
	}

	@Test func onlyALockoutKeepsTouchIDShownWhenItCannotBeUsed() {
		#expect(KeychainUnlockKeyStore.availability(canEvaluate: true, error: nil) == .available)
		#expect(KeychainUnlockKeyStore.availability(canEvaluate: false, error: NSError(domain: LAErrorDomain, code: LAError.Code.biometryLockout.rawValue)) == .lockedOut)
		#expect(KeychainUnlockKeyStore.availability(canEvaluate: false, error: NSError(domain: LAErrorDomain, code: LAError.Code.biometryNotEnrolled.rawValue)) == .unavailable)
		#expect(KeychainUnlockKeyStore.availability(canEvaluate: false, error: nil) == .unavailable)
	}

	@Test func theKeyIsCopiedOnlyAfterTheTouchAndThroughItsContext() async throws {
		let context = LAContext()
		let key = SymmetricKey(data: Data(repeating: 9, count: 32))
		var steps: [String] = []

		let read = try await KeychainUnlockKeyStore.read(through: context) {
			steps.append($0 === context ? "copy" : "copy through another context")
			return .key(key)
		} evaluate: { touched, _ in
			steps.append(touched === context ? "evaluate" : "evaluate another context")
		}

		#expect(read == .key(key))
		#expect(steps == ["evaluate", "copy"])
		#expect(isInvalidated(context))
	}

	@Test func theKeyIsKeptForTheFingersEnrolledWhenItWasSavedOnThisMacOnly() throws {
		let expected = try #require(SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, nil))

		#expect(CFEqual(try KeychainUnlockKeyStore.accessControl(), expected))
	}

	@Test func theTouchIsCheckedAgainstTheProtectionTheKeyIsSavedWith() async throws {
		var checked: [SecAccessControl] = []

		_ = try await KeychainUnlockKeyStore.read(through: LAContext()) { _ in .cancelled } evaluate: { checked.append($1) }

		#expect(checked.count == 1)
		#expect(try checked.allSatisfy { CFEqual($0, try KeychainUnlockKeyStore.accessControl()) })
	}

	@Test func everyKeychainReadEndsItsContextWhateverTheOutcome() async {
		let refusals: [Error] = [
			LAError(.authenticationFailed),
			LAError(.biometryLockout),
			LAError(.userCancel),
			LAError(.biometryNotAvailable),
			KeychainFailure(status: errSecParam),
		]
		for refusal in refusals {
			let context = LAContext()
			_ = try? await KeychainUnlockKeyStore.read(through: context) { _ in
				Issue.record("Copied the key after \(refusal)")
				return .cancelled
			} evaluate: { _, _ in
				throw refusal
			}
			#expect(isInvalidated(context), "\(refusal)")
		}

		let context = LAContext()
		await #expect(throws: KeychainFailure(status: errSecItemNotFound)) {
			try await KeychainUnlockKeyStore.read(through: context) { _ in
				throw KeychainFailure(status: errSecItemNotFound)
			} evaluate: { _, _ in }
		}
		#expect(isInvalidated(context))
	}

	@Test func theKeyIsCopiedThroughTheTouchedContextWithoutAskingForMore() throws {
		let context = LAContext()
		let bytes = Data(repeating: 5, count: 32)
		var asked: [(context: LAContext?, allowsInteraction: Bool?)] = []

		let read = try KeychainUnlockKeyStore(directory: temporaryDirectory()).copyKey(through: context) { query, result in
			let through = (query as NSDictionary)[kSecUseAuthenticationContext as String] as? LAContext
			asked.append((through, through.map { !$0.interactionNotAllowed }))
			result?.pointee = bytes as NSData
			return errSecSuccess
		}

		#expect(read == .key(SymmetricKey(data: bytes)))
		#expect(asked.count == 1)
		#expect(asked.first?.context === context)
		#expect(asked.first?.allowsInteraction == false)
	}

	@Test func eachKeychainAnswerAfterTheTouchBecomesWhatTheLockScreenShows() throws {
		let keys = KeychainUnlockKeyStore(directory: temporaryDirectory())
		func copy(answering status: OSStatus) throws -> StoredKeyRead {
			try keys.copyKey(through: LAContext()) { _, _ in status }
		}

		#expect(try copy(answering: errSecUserCanceled) == .cancelled)
		#expect(try copy(answering: errSecAuthFailed) == .cancelled)
		#expect(throws: KeychainFailure(status: errSecInteractionNotAllowed)) { try copy(answering: errSecInteractionNotAllowed) }
		#expect(throws: KeychainFailure(status: errSecItemNotFound)) { try copy(answering: errSecItemNotFound) }
	}

	@Test func readingTheKeyAfterTheTouchNeverAsksForMore() {
		let context = LAContext()

		#expect(throws: KeychainFailure.self) {
			try KeychainUnlockKeyStore(directory: temporaryDirectory()).copyKey(through: context)
		}

		#expect(context.interactionNotAllowed)
	}

	@Test func anAppWithoutTheKeychainEntitlementCannotUseTouchID() {
		#expect(KeychainUnlockKeyStore(directory: temporaryDirectory()).availability == .unavailable)
	}
}
