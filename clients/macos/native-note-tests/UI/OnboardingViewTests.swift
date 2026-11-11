import AppKit
import CryptoKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI
import Testing

@testable import NativeNote
@testable import NativeNoteKit

@MainActor
private final class Calls {
	var created: [String] = []
	var touchID: [String] = []
	var finished = 0
	var listened = 0
}

@MainActor @Suite(.takesFocus)
struct OnboardingViewTests {
	private func onboarding(
		_ calls: Calls,
		libraryExists: Bool = false,
		create: @escaping (String) async -> AppModel.Failure? = { _ in nil },
		hasSecureEnclave: Bool = true,
		touchIDAvailable: Bool = false,
		turnOnTouchID: @escaping (String) async -> AppModel.Failure? = { _ in nil },
		touchID: TouchIDControls = TouchIDControls(),
		sync: SyncControls = SyncControls()
	) -> OffscreenWindow<OnboardingView> {
		OffscreenWindow(
			OnboardingView(
				libraryExists: libraryExists,
				createLibrary: { password in
					calls.created.append(password)
					return await create(password)
				},
				hasSecureEnclave: hasSecureEnclave,
				touchIDAvailable: touchIDAvailable,
				turnOnTouchID: { password in
					calls.touchID.append(password)
					return await turnOnTouchID(password)
				},
				touchID: touchID,
				sync: sync,
				finish: { calls.finished += 1 }
			),
			width: 720,
			height: 560,
			catchesSheets: true
		)
	}

	private func texts(_ offscreen: OffscreenWindow<OnboardingView>) -> [String] {
		offscreen.accessibilityElements().filter { [.staticText, NSAccessibility.Role(rawValue: "AXHeading")].contains($0.role) }.map { $0.value.isEmpty ? $0.label : $0.value }
	}

	private func button(_ label: String, in offscreen: OffscreenWindow<OnboardingView>) -> AccessibilityElement? {
		offscreen.accessibilityElements(.button).first { $0.label == label }
	}

	private func press(_ label: String, in offscreen: OffscreenWindow<OnboardingView>) throws {
		try #require(button(label, in: offscreen), "\(label)").press()
		offscreen.pump()
	}

	private func field(_ placeholder: String, in offscreen: OffscreenWindow<OnboardingView>) throws -> NSSecureTextField {
		try #require(offscreen.views(of: NSSecureTextField.self).first { $0.placeholderString == placeholder })
	}

	private func type(_ text: String, into field: NSTextField, of offscreen: OffscreenWindow<OnboardingView>) throws {
		try #require(offscreen.window.makeFirstResponder(field))
		try #require(field.currentEditor()).insertText(text)
		offscreen.pump()
	}

	private func enterPassword(_ password: String, confirming confirmation: String? = nil, in offscreen: OffscreenWindow<OnboardingView>) throws {
		try press("Next", in: offscreen)
		try type(password, into: try field("Password", in: offscreen), of: offscreen)
		let confirm = try field("Confirm Password", in: offscreen)
		try type(confirmation ?? password, into: confirm, of: offscreen)
		confirm.currentEditor()?.insertNewline(nil)
	}

	@Test func welcomeLeadsToThePasswordStepWithTwoFieldsAsTallAsTheUnlockField() async throws {
		let offscreen = onboarding(Calls())
		defer { offscreen.close() }
		offscreen.pump()
		#expect(texts(offscreen).contains("Welcome to Native Note"))
		#expect(texts(offscreen).contains("A personal encrypted self-hosted note-taking app"))
		#expect(offscreen.views(of: NSSecureTextField.self).isEmpty)

		try press("Next", in: offscreen)

		#expect(texts(offscreen).contains("Set an Unlock Password"))
		#expect(texts(offscreen).contains("The app is encrypted with this password. It cannot be recovered."))
		let password = offscreen.onScreen(try field("Password", in: offscreen))
		let confirmation = offscreen.onScreen(try field("Confirm Password", in: offscreen))
		#expect(password.midY - confirmation.midY == UnlockView.fieldHeight + 10)
		let field = try field("Password", in: offscreen)
		await offscreen.pump { offscreen.window.firstResponder === field.currentEditor() }
		#expect(offscreen.window.firstResponder === field.currentEditor())
	}

	@Test func matchingPasswordsCreateTheLibraryOnceWithAnIndicatorInNextWhileItWorks() async throws {
		let calls = Calls()
		let gate = Latch()
		let offscreen = onboarding(calls, create: { _ in
			await gate.wait()
			return nil
		})
		defer { offscreen.close() }

		try enterPassword("correct horse", in: offscreen)
		await offscreen.pump { !calls.created.isEmpty }

		#expect(calls.created == ["correct horse"])
		let next = try #require(button("Next", in: offscreen))
		#expect(!next.isEnabled)
		#expect(next.value == OnboardingLabel.busyValue)
		#expect(offscreen.views(of: NSSecureTextField.self).allSatisfy { !$0.isEnabled })

		gate.release()
		await offscreen.pump { texts(offscreen).contains("Sync Your Notes") }

		#expect(texts(offscreen).contains("Sync Your Notes"))
		#expect(calls.created == ["correct horse"])
	}

	@Test func mismatchedPasswordsCreateNothingAndSaySo() async throws {
		let calls = Calls()
		let offscreen = onboarding(calls)
		defer { offscreen.close() }

		try enterPassword("correct horse", confirming: "correct hose", in: offscreen)
		await offscreen.pump(turns: 40) { !calls.created.isEmpty }

		#expect(calls.created.isEmpty)
		#expect(try field("Password", in: offscreen).stringValue == "correct horse")
		#expect(texts(offscreen).contains("The passwords do not match."))
	}

	@Test func aFailedCreateStaysOnThePasswordStep() async throws {
		let calls = Calls()
		let offscreen = onboarding(calls, create: { _ in .unexpected("disk full") })
		defer { offscreen.close() }

		try enterPassword("correct horse", in: offscreen)
		await offscreen.pump { button("Next", in: offscreen)?.isEnabled == true || !texts(offscreen).contains("Set an Unlock Password") }

		#expect(texts(offscreen).contains("Set an Unlock Password"))
		#expect(!texts(offscreen).contains("Sync Your Notes"))
	}

	@Test func thePasswordStepWarnsOnlyWithoutASecureEnclave() throws {
		for hasSecureEnclave in [false, true] {
			let offscreen = onboarding(Calls(), hasSecureEnclave: hasSecureEnclave)
			defer { offscreen.close() }
			try press("Next", in: offscreen)

			#expect(texts(offscreen).contains(OnboardingView.noSecureEnclaveWarning) == !hasSecureEnclave)
		}
	}

	@Test func settingUpNeverListensForTouchID() throws {
		let calls = Calls()
		let offscreen = onboarding(calls, touchID: TouchIDControls(state: .listening(LAContext()), listen: { _ in calls.listened += 1 }))
		defer { offscreen.close() }
		try press("Next", in: offscreen)
		offscreen.pump(for: 0.1)

		#expect(offscreen.views(of: LAAuthenticationView.self).isEmpty)
		#expect(calls.listened == 0)
	}

	@Test func whereTouchIDIsAvailableItIsOfferedWithTheNewPasswordAndThenSync() async throws {
		let calls = Calls()
		let offscreen = onboarding(calls, touchIDAvailable: true)
		defer { offscreen.close() }

		try enterPassword("correct horse", in: offscreen)
		await offscreen.pump { texts(offscreen).contains("Unlock with Touch ID?") }
		#expect(texts(offscreen).contains("Unlock the app with your fingerprint"))
		#expect(button("Set Up Touch ID", in: offscreen) != nil && button("Skip", in: offscreen) != nil)
		let primary = try #require(button("Set Up Touch ID", in: offscreen)).frame
		let secondary = try #require(button("Skip", in: offscreen)).frame
		#expect(primary.minY > secondary.maxY)
		#expect(primary.width == secondary.width)

		try press("Set Up Touch ID", in: offscreen)
		await offscreen.pump { texts(offscreen).contains("Sync Your Notes") }

		#expect(calls.touchID == ["correct horse"])
	}

	@Test func skippingTouchIDGoesToSyncWithoutTurningItOn() async throws {
		let calls = Calls()
		let offscreen = onboarding(calls, touchIDAvailable: true)
		defer { offscreen.close() }
		try enterPassword("correct horse", in: offscreen)
		await offscreen.pump { texts(offscreen).contains("Unlock with Touch ID?") }

		try press("Skip", in: offscreen)

		#expect(texts(offscreen).contains("Sync Your Notes"))
		#expect(calls.touchID.isEmpty)
	}

	@Test func aTouchIDFailureStaysOnTheStepWithItsReasonAndSkipStillLeaves() async throws {
		let calls = Calls()
		let offscreen = onboarding(calls, touchIDAvailable: true, turnOnTouchID: { _ in .failed("Touch ID was cancelled.", title: "") })
		defer { offscreen.close() }
		try enterPassword("correct horse", in: offscreen)
		await offscreen.pump { texts(offscreen).contains("Unlock with Touch ID?") }

		try press("Set Up Touch ID", in: offscreen)
		await offscreen.pump { texts(offscreen).contains("Touch ID was cancelled.") }
		#expect(texts(offscreen).contains("Unlock with Touch ID?"))

		try press("Skip", in: offscreen)
		#expect(texts(offscreen).contains("Sync Your Notes"))
	}

	@Test func skippingWhileWaitingForTheTouchCancelsItAndALateAnswerChangesNothing() async throws {
		let calls = Calls()
		let gate = Latch()
		var cancelled = 0
		let offscreen = onboarding(
			calls,
			touchIDAvailable: true,
			turnOnTouchID: { _ in
				await gate.wait()
				return nil
			},
			touchID: TouchIDControls(state: .listening(LAContext()), cancel: { cancelled += 1 })
		)
		defer { offscreen.close() }
		try enterPassword("correct horse", in: offscreen)
		await offscreen.pump { texts(offscreen).contains("Unlock with Touch ID?") }
		try press("Set Up Touch ID", in: offscreen)
		await offscreen.pump { !calls.touchID.isEmpty }

		try press("Skip", in: offscreen)
		gate.release()
		offscreen.pump(for: 0.1)

		#expect(cancelled == 1)
		#expect(texts(offscreen).contains("Sync Your Notes"))
	}

	@Test func theSyncStepLinksTheServerGuideAndNotNowFinishes() throws {
		let calls = Calls()
		let offscreen = onboarding(calls, libraryExists: true)
		defer { offscreen.close() }
		offscreen.pump()

		#expect(texts(offscreen).contains("Sync Your Notes"))
		#expect(texts(offscreen).contains { $0.contains("Native Note server") && $0.contains("sync your encrypted notes across devices") })
		let primary = try #require(button("Set Up", in: offscreen)).frame
		let secondary = try #require(button("Not Now", in: offscreen)).frame
		#expect(primary.minY > secondary.maxY)

		try press("Not Now", in: offscreen)

		#expect(calls.finished == 1)
	}

	@Test func theServerLinkPointsAtTheSyncServerGuide() throws {
		let links = OnboardingView.syncSubtitle.runs.compactMap { run in run.link.map { (String(OnboardingView.syncSubtitle[run.range].characters), $0) } }
		#expect(links.map(\.0) == ["Native Note server"])
		#expect(links.map(\.1) == [Guide.syncServer])
		#expect(Guide.syncServer.absoluteString == "https://git.hloth.dev/hloth/native-note/src/branch/main/docs/guides/setup-sync-server.md")

		let offscreen = onboarding(Calls(), libraryExists: true)
		defer { offscreen.close() }
		offscreen.pump()
		let link = try #require(offscreen.accessibilityElements(.link).first)
		#expect(link.label == "Native Note server" || link.value == "Native Note server")
	}

	@Test func turningSyncOnInTheSheetFinishesOnboardingThoughTheStatusItWasGivenIsStale() async throws {
		let calls = Calls()
		let words = try #require(Mnemonic.words(for: SymmetricKey(data: (0 ..< 32).map { UInt8($0 * 3 + 2) })))
		let sync = SyncControls(prepareSync: { _, _ in .success(.newLibrary(.init(words: words, checked: [0, 1, 2]))) }, finishSync: { _ in nil })
		#expect(sync.status.server == nil)
		let offscreen = onboarding(calls, libraryExists: true, sync: sync)
		defer { offscreen.close() }
		try press("Set Up", in: offscreen)
		await offscreen.pump { offscreen.sheet != nil }
		let sheet = try #require(offscreen.sheet)
		func editable() -> [NSTextField] {
			offscreen.sheetViews(of: NSTextField.self).filter(\.isEditable).sorted { offscreen.window.convertToScreen($0.convert($0.bounds, to: nil)).maxY > offscreen.window.convertToScreen($1.convert($1.bounds, to: nil)).maxY }
		}
		func fill(_ texts: [String]) throws {
			for (field, text) in zip(editable(), texts) {
				try #require(sheet.makeFirstResponder(field))
				try #require(field.currentEditor()).insertText(text)
				offscreen.pump()
			}
		}
		func pressInSheet(_ label: String) async throws {
			await offscreen.pump { offscreen.sheetAccessibilityElements(.button).contains { $0.label == label && $0.isEnabled } }
			try #require(offscreen.sheetAccessibilityElements(.button).first { $0.label == label }, "\(label)").press()
			offscreen.pump()
		}

		try fill(["http://127.0.0.1:8080", "0a0b"])
		try await pressInSheet("Continue")
		await offscreen.pump { offscreen.sheetAccessibilityElements(.button).contains { $0.label == "Reveal" } }
		try await pressInSheet("Continue")
		await offscreen.pump { editable().count == 3 }
		try fill(Array(words.prefix(3)))
		try await pressInSheet("Turn On Sync")
		await offscreen.pump { calls.finished > 0 }

		#expect(calls.finished == 1)
	}

	@Test func setUpOpensTheSettingsSyncSheetAndCancellingItKeepsTheStep() async throws {
		let calls = Calls()
		let offscreen = onboarding(calls, libraryExists: true)
		defer { offscreen.close() }

		try press("Set Up", in: offscreen)
		await offscreen.pump { offscreen.sheet != nil }
		let sheet = try #require(offscreen.sheet?.contentView)
		#expect(offscreen.sheetAccessibilityElements(NSAccessibility.Role(rawValue: "AXHeading")).contains { $0.label == "Set Up Sync" || $0.value == "Set Up Sync" })
		#expect(!sheet.subviews.isEmpty)

		try #require(offscreen.sheetAccessibilityElements(.button).first { $0.label == "Cancel" }).press()
		await offscreen.pump { offscreen.sheet == nil }

		#expect(calls.finished == 0)
		#expect(texts(offscreen).contains("Sync Your Notes"))
	}
}
