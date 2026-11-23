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
	var announced: [String] = []
	var voiceOver: [String] = []
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
				announce: { calls.announced.append($0) },
				voiceOverMoved: { calls.voiceOver.append($0) },
				finish: { calls.finished += 1 }
			),
			width: 720,
			height: 560,
			catchesSheets: true
		)
	}

	private func enterPassword(_ password: String, confirming confirmation: String? = nil, in offscreen: OffscreenWindow<OnboardingView>) throws {
		try offscreen.press("Next")
		try offscreen.type(password, into: try offscreen.field("Password"))
		let confirm = try offscreen.field("Confirm Password")
		try offscreen.type(confirmation ?? password, into: confirm)
		confirm.currentEditor()?.insertNewline(nil)
	}

	@Test func welcomeLeadsToThePasswordStepWithTwoFieldsAsTallAsTheUnlockField() async throws {
		let offscreen = onboarding(Calls())
		defer { offscreen.close() }
		offscreen.pump()
		#expect(offscreen.texts().contains("Welcome to Native Note"))
		#expect(offscreen.texts().contains("A personal encrypted self-hosted note-taking app"))
		#expect(offscreen.views(of: NSSecureTextField.self).isEmpty)

		try offscreen.press("Next")

		#expect(offscreen.texts().contains("Set an Unlock Password"))
		#expect(offscreen.texts().contains("The app is encrypted with this password. It cannot be recovered."))
		let password = offscreen.onScreen(try offscreen.field("Password"))
		let confirmation = offscreen.onScreen(try offscreen.field("Confirm Password"))
		#expect(password.midY - confirmation.midY == UnlockView.fieldHeight + 10)
		let field = try offscreen.field("Password")
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
		let next = try #require(offscreen.button("Next"))
		#expect(!next.isEnabled)
		#expect(next.value == OnboardingLabel.busyValue)
		#expect(offscreen.views(of: NSSecureTextField.self).allSatisfy { !$0.isEnabled })

		gate.release()
		await offscreen.pump { offscreen.texts().contains("Sync Your Notes") }

		#expect(offscreen.texts().contains("Sync Your Notes"))
		#expect(calls.created == ["correct horse"])
	}

	@Test func mismatchedPasswordsCreateNothingAndSaySo() async throws {
		let calls = Calls()
		let offscreen = onboarding(calls)
		defer { offscreen.close() }

		try enterPassword("correct horse", confirming: "correct hose", in: offscreen)
		await offscreen.pump { offscreen.texts().contains("The passwords do not match.") }
		offscreen.pump(for: 0.2)

		#expect(calls.created.isEmpty)
		#expect(try offscreen.field("Password").stringValue == "correct horse")
		#expect(offscreen.texts().contains("The passwords do not match."))
		#expect(calls.announced == ["The passwords do not match."])

		let confirm = try offscreen.field("Confirm Password")
		try #require(offscreen.window.makeFirstResponder(confirm))
		try #require(confirm.currentEditor()).insertNewline(nil)
		offscreen.pump()

		#expect(calls.announced == ["The passwords do not match.", "The passwords do not match."])
		#expect(calls.created.isEmpty)
	}

	@Test func aFailedCreateStaysOnThePasswordStep() async throws {
		let calls = Calls()
		let offscreen = onboarding(calls, create: { _ in .unexpected("disk full") })
		defer { offscreen.close() }

		try enterPassword("correct horse", in: offscreen)
		await offscreen.pump { offscreen.button("Next")?.isEnabled == true || !offscreen.texts().contains("Set an Unlock Password") }

		#expect(offscreen.texts().contains("Set an Unlock Password"))
		#expect(!offscreen.texts().contains("Sync Your Notes"))
	}

	@Test func thePasswordStepWarnsOnlyWithoutASecureEnclave() throws {
		for hasSecureEnclave in [false, true] {
			let offscreen = onboarding(Calls(), hasSecureEnclave: hasSecureEnclave)
			defer { offscreen.close() }
			try offscreen.press("Next")

			#expect(offscreen.texts().contains(OnboardingView.noSecureEnclaveWarning) == !hasSecureEnclave)
		}
	}

	@Test func settingUpNeverListensForTouchID() throws {
		let calls = Calls()
		let offscreen = onboarding(calls, touchID: TouchIDControls(state: .listening(LAContext()), listen: { _ in calls.listened += 1 }))
		defer { offscreen.close() }
		try offscreen.press("Next")
		offscreen.pump(for: 0.1)

		#expect(offscreen.views(of: LAAuthenticationView.self).isEmpty)
		#expect(calls.listened == 0)
	}

	@Test func whereTouchIDIsAvailableItIsOfferedWithTheNewPasswordAndThenSync() async throws {
		let calls = Calls()
		let offscreen = onboarding(calls, touchIDAvailable: true)
		defer { offscreen.close() }

		try enterPassword("correct horse", in: offscreen)
		await offscreen.pump { offscreen.texts().contains("Unlock with Touch ID?") }
		#expect(offscreen.texts().contains("Unlock the app with your fingerprint"))
		#expect(offscreen.button("Set Up Touch ID") != nil && offscreen.button("Skip") != nil)
		let primary = try #require(offscreen.button("Set Up Touch ID")).frame
		let secondary = try #require(offscreen.button("Skip")).frame
		#expect(primary.minY > secondary.maxY)
		#expect(primary.width == secondary.width)

		try offscreen.press("Set Up Touch ID")
		await offscreen.pump { offscreen.texts().contains("Sync Your Notes") }

		#expect(calls.touchID == ["correct horse"])
	}

	@Test func skippingTouchIDGoesToSyncWithoutTurningItOn() async throws {
		let calls = Calls()
		let offscreen = onboarding(calls, touchIDAvailable: true)
		defer { offscreen.close() }
		try enterPassword("correct horse", in: offscreen)
		await offscreen.pump { offscreen.texts().contains("Unlock with Touch ID?") }

		try offscreen.press("Skip")

		#expect(offscreen.texts().contains("Sync Your Notes"))
		#expect(calls.touchID.isEmpty)
	}

	private func heads(_ title: String, in offscreen: OffscreenWindow<some View>) -> Bool {
		offscreen.accessibilityElements().contains { $0.role == NSAccessibility.Role(rawValue: "AXHeading") && ($0.value.isEmpty ? $0.label : $0.value) == title }
	}

	@Test func voiceOverIsAskedToMoveToTheTitleOfEachStepThePasswordLeadsTo() async throws {
		let calls = Calls()
		let offscreen = onboarding(calls, touchIDAvailable: true)
		defer { offscreen.close() }
		offscreen.pump(for: 0.1)
		#expect(calls.voiceOver.isEmpty)

		try enterPassword("correct horse", in: offscreen)
		await offscreen.pump { !calls.voiceOver.isEmpty }
		#expect(calls.voiceOver == ["Unlock with Touch ID?"])
		#expect(heads("Unlock with Touch ID?", in: offscreen))

		try offscreen.press("Skip")
		await offscreen.pump { calls.voiceOver.count == 2 }

		#expect(calls.voiceOver == ["Unlock with Touch ID?", "Sync Your Notes"])
		#expect(heads("Sync Your Notes", in: offscreen))
	}

	@Test func withoutTouchIDThePasswordAsksVoiceOverToMoveToTheSyncTitleButAWindowOpeningThereDoesNot() async throws {
		let calls = Calls()
		let offscreen = onboarding(calls)
		defer { offscreen.close() }
		try enterPassword("correct horse", in: offscreen)
		await offscreen.pump { !calls.voiceOver.isEmpty }
		#expect(calls.voiceOver == ["Sync Your Notes"])
		#expect(heads("Sync Your Notes", in: offscreen))

		let reopened = Calls()
		let returning = onboarding(reopened, libraryExists: true)
		defer { returning.close() }
		returning.pump(for: 0.1)

		#expect(returning.texts().contains("Sync Your Notes"))
		#expect(reopened.voiceOver.isEmpty)
	}

	@Test func aTouchIDFailureStaysOnTheStepWithItsReasonAndSkipStillLeaves() async throws {
		let calls = Calls()
		let offscreen = onboarding(calls, touchIDAvailable: true, turnOnTouchID: { _ in .failed("Touch ID was cancelled.", title: "") })
		defer { offscreen.close() }
		try enterPassword("correct horse", in: offscreen)
		await offscreen.pump { offscreen.texts().contains("Unlock with Touch ID?") }

		try offscreen.press("Set Up Touch ID")
		await offscreen.pump { offscreen.texts().contains("Touch ID was cancelled.") }
		#expect(offscreen.texts().contains("Unlock with Touch ID?"))
		#expect(calls.announced == ["Touch ID was cancelled."])

		try offscreen.press("Skip")
		#expect(offscreen.texts().contains("Sync Your Notes"))
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
		await offscreen.pump { offscreen.texts().contains("Unlock with Touch ID?") }
		try offscreen.press("Set Up Touch ID")
		await offscreen.pump { !calls.touchID.isEmpty }

		await offscreen.pump { !calls.announced.isEmpty }
		#expect(calls.announced == [OnboardingView.touchIDLine])

		try offscreen.press("Skip")
		gate.release()
		offscreen.pump(for: 0.1)

		#expect(cancelled == 1)
		#expect(offscreen.texts().contains("Sync Your Notes"))
		#expect(calls.announced == [OnboardingView.touchIDLine])
	}

	@Test func theSyncStepLinksTheServerGuideAndNotNowFinishes() throws {
		let calls = Calls()
		let offscreen = onboarding(calls, libraryExists: true)
		defer { offscreen.close() }
		offscreen.pump()

		#expect(offscreen.texts().contains("Sync Your Notes"))
		#expect(offscreen.texts().contains { $0.contains("Native Note server") && $0.contains("sync your encrypted notes across devices") })
		let primary = try #require(offscreen.button("Set Up")).frame
		let secondary = try #require(offscreen.button("Not Now")).frame
		#expect(primary.minY > secondary.maxY)

		try offscreen.press("Not Now")

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
		let sync = SyncControls(prepareSync: { _, _ in .success(.newLibrary(.init(words: words, positionsToConfirm: [0, 1, 2]))) }, finishSync: { _ in nil })
		#expect(sync.status.server == nil)
		let offscreen = onboarding(calls, libraryExists: true, sync: sync)
		defer { offscreen.close() }
		try offscreen.press("Set Up")
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

		try offscreen.press("Set Up")
		await offscreen.pump { offscreen.sheet != nil }
		let sheet = try #require(offscreen.sheet?.contentView)
		#expect(offscreen.sheetAccessibilityElements(NSAccessibility.Role(rawValue: "AXHeading")).contains { $0.label == "Set Up Sync" || $0.value == "Set Up Sync" })
		#expect(!sheet.subviews.isEmpty)

		try #require(offscreen.sheetAccessibilityElements(.button).first { $0.label == "Cancel" }).press()
		await offscreen.pump { offscreen.sheet == nil }

		#expect(calls.finished == 0)
		#expect(offscreen.texts().contains("Sync Your Notes"))
	}
}
