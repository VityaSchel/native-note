import AppKit
import CryptoKit
import Foundation
import LocalAuthentication
import SwiftUI
import Testing

@testable import NativeNote
@testable import NativeNoteKit

@MainActor
struct Screen {
	let view: AnyView
	let width: CGFloat
	let height: CGFloat
	let catchesSheets: Bool
	let measuresContrast: Bool
	let expectations: AuditExpectations
	let release: @MainActor () -> Void
	let drive: @MainActor (OffscreenWindow<AnyView>) async throws -> Void

	init(
		_ view: some View,
		width: CGFloat = 380,
		height: CGFloat = 620,
		catchesSheets: Bool = false,
		measuresContrast: Bool = true,
		expecting expectations: AuditExpectations = AuditExpectations(),
		holding latch: Latch? = nil,
		drive: @escaping @MainActor (OffscreenWindow<AnyView>) async throws -> Void = { _ in }
	) {
		self.view = AnyView(view)
		self.width = width
		self.height = height
		self.catchesSheets = catchesSheets
		self.measuresContrast = measuresContrast
		self.expectations = expectations
		release = { latch?.release() }
		self.drive = drive
	}

	func whileShown(_ body: (OffscreenWindow<AnyView>) async throws -> Void) async throws {
		let offscreen = OffscreenWindow(view, width: width, height: height, catchesSheets: catchesSheets)
		defer {
			release()
			offscreen.close()
		}
		try await drive(offscreen)
		offscreen.pump(for: 0.05)
		try await body(offscreen)
	}
}

enum ScreenGroup: String, CaseIterable, CustomTestStringConvertible {
	case unlockScreens, settingsScreens, noteRows, noteListWithSamples, noteListWithAnInitialSelection, noteListInsideASplitViewLikeTheApp
	case noteListEmpty, noteListWithoutMatches, editor, libraryShell, libraryShellWithNothingSelected, exchangeSheets, firstRunShell
	case lockScreenDialogs, onboardingPassword, onboardingTouchID, onboardingSyncSheet, syncSetupSteps, syncSection, touchIDSheet, passwordSheet
	case exportEncrypted, libraryWithSync, libraryAlertsAndSheets

	var testDescription: String { rawValue }

	var isDriven: Bool {
		switch self {
		case .unlockScreens, .settingsScreens, .noteRows, .noteListWithSamples, .noteListWithAnInitialSelection, .noteListInsideASplitViewLikeTheApp, .noteListEmpty, .noteListWithoutMatches, .editor, .libraryShell, .libraryShellWithNothingSelected, .exchangeSheets, .firstRunShell:
			false
		case .lockScreenDialogs, .onboardingPassword, .onboardingTouchID, .onboardingSyncSheet, .syncSetupSteps, .syncSection, .touchIDSheet, .passwordSheet, .exportEncrypted, .libraryWithSync, .libraryAlertsAndSheets:
			true
		}
	}

	// These show a host another group already measures; their own state is an Apple-drawn alert, a sheet measured as its own screen, or the toolbar.
	var measuresContrast: Bool {
		![.lockScreenDialogs, .onboardingSyncSheet, .libraryWithSync, .libraryAlertsAndSheets].contains(self)
	}

	@MainActor private func noteList(selection: UUID?, search: String = "", groups: [NoteGroup] = NoteGroup.samples) -> NoteListView {
		NoteListView(groups: groups, now: Note.sampleNow, selection: .constant(selection), search: .constant(search)) { _ in }
	}

	@MainActor var screens: [Screen] {
		switch self {
		case .unlockScreens:
			let states: [AppModel.TouchID] = [.listening(LAContext()), .paused(.inBackground), .paused(.checkingPassword), .paused(.shaking), .needsClick(after: .cancel), .lockedOut, .working]
			return [
				Screen(UnlockView(failure: nil, submit: { _ in nil }, dismissFailure: {})),
				Screen(UnlockView(failure: .wrongPassword, submit: { _ in nil }, dismissFailure: {})),
				Screen(OnboardingView(libraryExists: false, createLibrary: { _ in nil }, finish: {}), width: 720, height: 560),
				Screen(OnboardingView(libraryExists: true, createLibrary: { _ in nil }, finish: {}), width: 720, height: 560),
			] + states.map { Screen(UnlockView(failure: nil, submit: { _ in nil }, dismissFailure: {}, touchID: TouchIDControls(state: $0), eraseLibrary: {})) } + [
				Screen(UnlockView(failure: nil, submit: { _ in nil }, dismissFailure: {}, touchID: TouchIDControls(state: .paused(.shaking)), shake: AppModel.Shake(count: 1, isRunning: true), eraseLibrary: {})),
				Screen(UnlockView(failure: .wrongPassword, submit: { _ in nil }, dismissFailure: {}, eraseLibrary: {})),
				Screen(OnboardingView(libraryExists: false, createLibrary: { _ in nil }, hasSecureEnclave: false, finish: {}), width: 720, height: 560),
			]
		case .settingsScreens:
			let status = AppModel.SyncStatus(phase: .idle, server: "http://notes.example:8080/", lastSynced: Date(), problems: ["A note is larger than 1 MB."])
			var joining = SyncSetupForm(mode: .setUp)
			joining.prepared(.success(.existingLibrary))
			return [
				Screen(SettingsView(model: .previewingFirstRun), width: 440, height: 300),
				Screen(SettingsView(model: .previewing([])), width: 440, height: 300),
				Screen(SecuritySettings.stubbed(touchIDEnabled: true), width: 440, height: 300),
				Screen(SecuritySettings.stubbed(touchIDAvailable: false), width: 440, height: 300),
				Screen(ChangePasswordView(change: { _, _ in nil }, done: {}), width: 360, height: 300),
				Screen(TurnOnTouchIDView(turnOn: { _ in nil }, done: {}), width: 360, height: 160),
				Screen(SecuritySettings.stubbed(status: status), width: 440, height: 520),
				Screen(SyncSetupView(mode: .setUp, controls: SyncControls(), done: {}), width: 440, height: 300),
				Screen(SyncSetupView(form: joining, controls: SyncControls(), done: {}), width: 440, height: 560),
				Screen(RecoveryWords(words: (1 ... 24).map { "word\($0)" }), width: 440, height: 260),
			]
		case .noteRows:
			return [
				Screen(
					List {
						ZStack(alignment: .leading) { NoteRow(note: .sample(1, "Shopping\nquartz, bread, and a new kettle", minutesAgo: 5), now: Note.sampleNow) }
						ZStack(alignment: .leading) { NoteRow(note: .sample(3, "", minutesAgo: 200), now: Note.sampleNow) }
					}
				),
			]
		case .noteListWithSamples:
			return [Screen(NavigationStack { noteList(selection: nil) })]
		case .noteListWithAnInitialSelection:
			return [Screen(NavigationStack { noteList(selection: NoteGroup.samples[0].notes[0].id) })]
		case .noteListInsideASplitViewLikeTheApp:
			return [
				Screen(
					NavigationSplitView {
						List { Label("All Notes", systemImage: "tray.full") }
					} content: {
						noteList(selection: NoteGroup.samples[0].notes[0].id)
					} detail: {
						Text("detail")
					},
					width: 980,
					height: 560
				),
			]
		case .noteListEmpty:
			return [Screen(NavigationStack { noteList(selection: nil, groups: []) })]
		case .noteListWithoutMatches:
			return [Screen(NavigationStack { noteList(selection: nil, search: "kayak", groups: []) })]
		case .editor:
			return [Screen(NoteEditor(text: .constant("Shopping\n\nquartz and bread"))), Screen(NoteEditor(text: .constant("")))]
		case .libraryShell:
			return [Screen(ContentView(exchange: LibraryExchange(model: .previewing(NoteGroup.samples.flatMap(\.notes)))), width: 980, height: 560)]
		case .libraryShellWithNothingSelected:
			let model = AppModel.previewing(NoteGroup.samples.flatMap(\.notes))
			model.selection = nil
			return [Screen(ContentView(exchange: LibraryExchange(model: model)), width: 980, height: 560)]
		case .exchangeSheets:
			return [
				Screen(ExportSheet(export: { _ in }, cancel: {})),
				Screen(ImportPassphraseSheet(refused: true, working: false, submit: { _ in }, cancel: {})),
				Screen(ImportPassphraseSheet(refused: false, working: true, submit: { _ in }, cancel: {})),
			]
		case .firstRunShell:
			return [Screen(ContentView(exchange: LibraryExchange(model: .previewingFirstRun)))]
		case .lockScreenDialogs:
			return DrivenScreens.lockScreenDialogs
		case .onboardingPassword:
			return DrivenScreens.onboardingPassword
		case .onboardingTouchID:
			return DrivenScreens.onboardingTouchID
		case .onboardingSyncSheet:
			return DrivenScreens.onboardingSyncSheet
		case .syncSetupSteps:
			return DrivenScreens.syncSetupSteps
		case .syncSection:
			return DrivenScreens.syncSection
		case .touchIDSheet:
			return DrivenScreens.touchIDSheet
		case .passwordSheet:
			return DrivenScreens.passwordSheet
		case .exportEncrypted:
			return DrivenScreens.exportEncrypted
		case .libraryWithSync:
			return DrivenScreens.libraryWithSync
		case .libraryAlertsAndSheets:
			return DrivenScreens.libraryAlertsAndSheets
		}
	}
}

@MainActor
private enum DrivenScreens {
	static let server = "http://notes.example:8080/"
	static let unreachable = "The server could not be reached."
	static let words = Mnemonic.words(for: SymmetricKey(data: Data((0 ..< 32).map { UInt8($0 * 5 + 1) }))) ?? []
	static let phrase = AppModel.RecoveryPhrase(words: words, positionsToConfirm: [2, 10, 19])

	static var clipboard: RecoveryClipboard {
		RecoveryClipboard(NSPasteboard(name: .init("dev.hloth.nativenote.tests.unused")))
	}

	static func onboarding(
		libraryExists: Bool = false,
		create: @escaping (String) async -> AppModel.Failure? = { _ in nil },
		hasSecureEnclave: Bool = true,
		touchIDAvailable: Bool = false,
		turnOnTouchID: @escaping (String) async -> AppModel.Failure? = { _ in nil },
		touchID: TouchIDControls = TouchIDControls()
	) -> OnboardingView {
		OnboardingView(
			libraryExists: libraryExists,
			createLibrary: create,
			hasSecureEnclave: hasSecureEnclave,
			touchIDAvailable: touchIDAvailable,
			turnOnTouchID: turnOnTouchID,
			touchID: touchID,
			clipboard: clipboard,
			announce: { _ in },
			finish: {}
		)
	}

	static func setup(_ form: SyncSetupForm, controls: SyncControls = SyncControls()) -> SyncSetupView {
		SyncSetupView(form: form, controls: controls, clipboard: clipboard, announce: { _ in }, announceStep: { _ in }, done: {})
	}

	static var lockScreenDialogs: [Screen] {
		[
			Screen(
				UnlockView(failure: .wrongPassword, submit: { _ in nil }, dismissFailure: {}, eraseLibrary: {}, announce: { _ in }),
				catchesSheets: true,
				expecting: AuditExpectations(mustHear: [UnlockView.eraseTitle, UnlockView.eraseMessage, UnlockView.eraseAction])
			) { offscreen in
				try offscreen.pressLink("Forgot Password?")
				await offscreen.pump { offscreen.sheet != nil }
			},
			Screen(
				UnlockView(failure: .unexpected("The notes database could not be opened."), submit: { _ in nil }, dismissFailure: {}, announce: { _ in }),
				catchesSheets: true,
				expecting: AuditExpectations(mustHear: ["Native Note could not continue.", "The notes database could not be opened."])
			) { offscreen in
				await offscreen.pump { offscreen.sheet != nil }
			},
		]
	}

	static var onboardingPassword: [Screen] {
		let creating = Latch()
		return [
			Screen(onboarding(), width: 720, height: 560, expecting: AuditExpectations(mustHear: ["Set an Unlock Password", "The app is encrypted with this password. It cannot be recovered."])) { offscreen in
				try offscreen.press("Next")
			},
			Screen(onboarding(hasSecureEnclave: false), width: 720, height: 560, expecting: AuditExpectations(mustHear: [OnboardingView.noSecureEnclaveWarning, "The passwords do not match."])) { offscreen in
				try offscreen.enterPasswords("correct horse", confirming: "battery staple")
				await offscreen.pump { offscreen.texts().contains("The passwords do not match.") }
			},
			Screen(
				onboarding(create: { _ in
					await creating.wait()
					return nil
				}),
				width: 720,
				height: 560,
				expecting: AuditExpectations(mustHear: ["Set an Unlock Password", OnboardingLabel.busyValue]),
				holding: creating
			) { offscreen in
				try offscreen.enterPasswords("correct horse", confirming: "correct horse")
				await offscreen.pump { creating.isHolding }
			},
		]
	}

	static var onboardingTouchID: [Screen] {
		let listening = Latch()
		let retrying = Latch()
		return [
			Screen(onboarding(touchIDAvailable: true), width: 720, height: 560, expecting: AuditExpectations(mustHear: ["Unlock with Touch ID?", "Unlock the app with your fingerprint."])) { offscreen in
				try await offscreen.reachTouchIDOffer()
			},
			Screen(
				onboarding(
					touchIDAvailable: true,
					turnOnTouchID: { _ in
						await listening.wait()
						return nil
					},
					touchID: TouchIDControls(state: .listening(LAContext()))
				),
				width: 720,
				height: 560,
				expecting: AuditExpectations(mustHear: [OnboardingView.touchIDLine, OnboardingLabel.busyValue], informativeImages: [OnboardingView.touchIDLabel]),
				holding: listening
			) { offscreen in
				try await offscreen.reachTouchIDOffer()
				try offscreen.press("Set Up Touch ID")
				await offscreen.pump { listening.isHolding }
			},
			Screen(
				onboarding(
					touchIDAvailable: true,
					turnOnTouchID: { _ in
						await retrying.wait()
						return nil
					},
					touchID: TouchIDControls(state: .needsClick(after: .miss))
				),
				width: 720,
				height: 560,
				expecting: AuditExpectations(mustHear: ["Touch ID didn't match.", TouchIDStatus.tryAgainTitle]),
				holding: retrying
			) { offscreen in
				try await offscreen.reachTouchIDOffer()
				try offscreen.press("Set Up Touch ID")
				await offscreen.pump { retrying.isHolding }
			},
			Screen(
				onboarding(touchIDAvailable: true, turnOnTouchID: { _ in .unexpected("The Secure Enclave refused the key.") }),
				width: 720,
				height: 560,
				expecting: AuditExpectations(mustHear: ["The Secure Enclave refused the key."])
			) { offscreen in
				try await offscreen.reachTouchIDOffer()
				try offscreen.press("Set Up Touch ID")
				await offscreen.pump { offscreen.texts().contains("The Secure Enclave refused the key.") }
			},
		]
	}

	static var onboardingSyncSheet: [Screen] {
		[
			Screen(onboarding(libraryExists: true), width: 720, height: 560, catchesSheets: true, expecting: AuditExpectations(mustHear: ["Sync Your Notes", "Set Up Sync"])) { offscreen in
				try offscreen.press("Set Up")
				await offscreen.pump { offscreen.sheet != nil }
			},
		]
	}

	static var syncSetupSteps: [Screen] {
		let checking = Latch()
		let preparing = Latch()
		var writing = SyncSetupForm(mode: .setUp)
		writing.prepared(.success(.newLibrary(phrase)))
		var confirming = writing
		confirming.confirm()
		var rotatedElsewhere = SyncSetupForm(mode: .rotate)
		rotatedElsewhere.rotationPrepared(.success(phrase))
		rotatedElsewhere.confirm()
		rotatedElsewhere.begin()
		rotatedElsewhere.finished(.rotatedElsewhere)
		var checksum = PhraseEntry()
		_ = checksum.set(Array(repeating: "abandon", count: PhraseEntry.count).joined(separator: " "), at: 0)
		let list = RecoveryClipboard.list(words)
		return [
			Screen(setup(writing), width: 440, height: 560, expecting: AuditExpectations(mustHear: ["Write Down Your Recovery Phrase", RecoveryWords.warning], mustNotHear: list.components(separatedBy: "\n"))),
			Screen(setup(writing), width: 440, height: 560, expecting: AuditExpectations(mustHear: [list])) { offscreen in
				try offscreen.press("Reveal")
			},
			Screen(setup(confirming), width: 440, height: 560, expecting: AuditExpectations(mustHear: ["Confirm Your Recovery Phrase", "Word 3", "Word 11", "Word 20"])),
			Screen(setup(confirming), width: 440, height: 560, expecting: AuditExpectations(mustHear: ["Word 3"], informativeImages: [PhraseFields.unknownWordLabel])) { offscreen in
				let field = try #require(offscreen.editableTextFields().first)
				try offscreen.type("zzzz", into: field)
				await offscreen.pump { !offscreen.accessibilityElements(.image).isEmpty }
			},
			Screen(setup(rotatedElsewhere), width: 440, height: 560, expecting: AuditExpectations(mustHear: ["Enter the Current Recovery Phrase", AppModel.SyncSetupFailure.rotatedElsewhere.message])),
			Screen(setup(SyncSetupForm(mode: .changeServer, server: "http://old.example:8080")), width: 440, height: 360, expecting: AuditExpectations(mustHear: ["Change Server", "Enter this library's server and its API key"])),
			Screen(
				setup(SyncSetupForm(mode: .rotate), controls: SyncControls(prepareRotation: {
					await preparing.wait()
					return .success(phrase)
				})),
				width: 440,
				height: 300,
				expecting: AuditExpectations(mustHear: ["Change Recovery Phrase", OnboardingLabel.busyValue]),
				holding: preparing
			) { offscreen in
				await offscreen.pump { preparing.isHolding }
			},
			Screen(
				setup(SyncSetupForm(mode: .setUp), controls: SyncControls(prepareSync: { _, _ in
					await checking.wait()
					return .failure(.refused)
				})),
				width: 440,
				height: 300,
				expecting: AuditExpectations(mustHear: ["Set Up Sync", OnboardingLabel.busyValue]),
				holding: checking
			) { offscreen in
				try offscreen.enterServer()
				await offscreen.pump { checking.isHolding }
			},
			Screen(
				setup(SyncSetupForm(mode: .setUp), controls: SyncControls(prepareSync: { _, _ in .failure(.refused) })),
				width: 440,
				height: 300,
				expecting: AuditExpectations(mustHear: [AppModel.SyncSetupFailure.refused.message])
			) { offscreen in
				try offscreen.enterServer()
				await offscreen.pump { offscreen.texts().contains(AppModel.SyncSetupFailure.refused.message) }
			},
			Screen(
				PhraseFields(entry: .constant(checksum), submit: {}, announce: { _ in }).textFieldStyle(.roundedBorder).padding(20).frame(width: 440),
				width: 440,
				height: 360,
				expecting: AuditExpectations(mustHear: [PhraseFields.checksumMessage, "Word 24"])
			),
		]
	}

	static var syncSection: [Screen] {
		let failed = AppModel.SyncStatus(phase: .failed(unreachable), server: server, lastSynced: Date())
		return [
			Screen(SecuritySettings.stubbed(), width: 440, height: 400, expecting: AuditExpectations(mustHear: ["Set Up Sync…", "Keep your notes on your own Native Note server, end-to-end encrypted."])),
			Screen(SecuritySettings.stubbed(status: AppModel.SyncStatus(phase: .syncing, server: server)), width: 440, height: 520, expecting: AuditExpectations(mustHear: ["Syncing…", OnboardingLabel.busyValue])),
			Screen(SecuritySettings.stubbed(status: failed), width: 440, height: 520, expecting: AuditExpectations(mustHear: ["Sync failed", unreachable])),
			Screen(SecuritySettings.stubbed(status: AppModel.SyncStatus(phase: .idle, server: server)), width: 440, height: 520, catchesSheets: true, expecting: AuditExpectations(mustHear: ["Turn Off Sync?", "This Mac keeps its notes and stops syncing them. The server keeps its copy."])) { offscreen in
				try offscreen.press("Turn Off Sync…")
				await offscreen.pump { offscreen.sheet != nil }
			},
		]
	}

	static var touchIDSheet: [Screen] {
		let listening = Latch()
		let retrying = Latch()
		return [
			Screen(SecuritySettings.stubbed(), width: 440, height: 400, catchesSheets: true, measuresContrast: false, expecting: AuditExpectations(mustHear: ["Turn On Touch ID Unlock", "Enter your password to unlock with Touch ID instead."])) { offscreen in
				try #require(offscreen.views(of: NSSwitch.self).first).performClick(nil)
				await offscreen.pump { offscreen.sheet != nil }
			},
			Screen(TurnOnTouchIDView(turnOn: { _ in .wrongPassword }, done: {}, announce: { _ in }), width: 380, height: 200, expecting: AuditExpectations(mustHear: ["Wrong password."])) { offscreen in
				try offscreen.submit("wrong horse", in: "Password:")
				await offscreen.pump { offscreen.texts().contains("Wrong password.") }
			},
			Screen(
				TurnOnTouchIDView(turnOn: { _ in
					await listening.wait()
					return nil
				}, done: {}, touchID: TouchIDControls(state: .listening(LAContext())), announce: { _ in }),
				width: 380,
				height: 200,
				expecting: AuditExpectations(mustHear: [TurnOnTouchIDView.touchIDLine], informativeImages: [TurnOnTouchIDView.touchIDLabel]),
				holding: listening
			) { offscreen in
				try offscreen.submit("correct horse", in: "Password:")
				await offscreen.pump { listening.isHolding }
			},
			Screen(
				TurnOnTouchIDView(turnOn: { _ in
					await retrying.wait()
					return nil
				}, done: {}, touchID: TouchIDControls(state: .needsClick(after: .miss)), announce: { _ in }),
				width: 380,
				height: 200,
				expecting: AuditExpectations(mustHear: ["Touch ID didn't match.", TouchIDStatus.tryAgainTitle]),
				holding: retrying
			) { offscreen in
				try offscreen.submit("correct horse", in: "Password:")
				await offscreen.pump { retrying.isHolding }
			},
		]
	}

	static var passwordSheet: [Screen] {
		let changing = Latch()
		return [
			Screen(ChangePasswordView(change: { _, _ in nil }, done: {}), width: 400, height: 300, expecting: AuditExpectations(mustHear: ["The new passwords do not match."])) { offscreen in
				try offscreen.type("correct horse", into: "Current Password:")
				try offscreen.type("battery staple", into: "New Password:")
				try offscreen.submit("battery stable", in: "Verify:")
				await offscreen.pump { offscreen.texts().contains("The new passwords do not match.") }
			},
			Screen(
				ChangePasswordView(change: { _, _ in
					await changing.wait()
					return nil
				}, done: {}),
				width: 400,
				height: 300,
				expecting: AuditExpectations(mustHear: ["Change Password", OnboardingLabel.busyValue]),
				holding: changing
			) { offscreen in
				try offscreen.type("correct horse", into: "Current Password:")
				try offscreen.type("battery staple", into: "New Password:")
				try offscreen.submit("battery staple", in: "Verify:")
				await offscreen.pump { changing.isHolding }
			},
		]
	}

	static var exportEncrypted: [Screen] {
		[
			Screen(ExportSheet(export: { _ in }, cancel: {}, announce: { _ in }), width: 400, height: 360, expecting: AuditExpectations(mustHear: ["The passphrases do not match."])) { offscreen in
				let fields = offscreen.secureFieldsTopDown()
				try #require(fields.count == 2)
				try offscreen.type("correct horse", into: fields[0])
				try offscreen.type("battery", into: fields[1])
				try #require(fields[1].currentEditor()).insertNewline(nil)
				await offscreen.pump { offscreen.texts().contains("The passphrases do not match.") }
			},
			Screen(ExportSheet(export: { _ in }, cancel: {}, announce: { _ in }), width: 400, height: 360, expecting: AuditExpectations(mustHear: ["Encrypt with a passphrase", "Export…"])) { offscreen in
				try #require(offscreen.accessibilityElements(.checkBox).first { $0.label == "Encrypt with a passphrase" }).press()
				await offscreen.pump { offscreen.views(of: NSSecureTextField.self).isEmpty }
			},
		]
	}

	static func library(_ model: AppModel = .previewing(NoteGroup.samples.flatMap(\.notes)), catchesSheets: Bool = false, expecting: AuditExpectations, drive: @escaping @MainActor (OffscreenWindow<AnyView>, LibraryExchange) async throws -> Void) -> Screen {
		let exchange = LibraryExchange(model: model)
		return Screen(ContentView(exchange: exchange, announce: { _ in }, syncAnnouncements: SyncAnnouncements()), width: 980, height: 560, catchesSheets: catchesSheets, expecting: expecting) { offscreen in
			try await drive(offscreen, exchange)
		}
	}

	static var libraryWithSync: [Screen] {
		let phases: [(AppModel.SyncStatus.Phase, String)] = [(.idle, "Last synced just now"), (.syncing, OnboardingLabel.busyValue), (.failed(unreachable), SyncSection.failureLine(unreachable))]
		return phases.map { phase, heard in
			library(expecting: AuditExpectations(mustHear: ["Sync Now", heard])) { offscreen, exchange in
				exchange.model.sync.status = AppModel.SyncStatus(phase: phase, server: server, lastSynced: Date())
				await offscreen.pump { offscreen.window.toolbar?.items.contains { $0.label == "Sync Now" } ?? false }
			}
		}
	}

	static var libraryAlertsAndSheets: [Screen] {
		[
			library(.previewing(NoteGroup.samples.flatMap(\.notes), failure: .unsaved("disk I/O error")), catchesSheets: true, expecting: AuditExpectations(mustHear: ["Your latest edits could not be saved.", "disk I/O error"])) { offscreen, _ in
				await offscreen.pump { offscreen.sheet != nil }
			},
			library(catchesSheets: true, expecting: AuditExpectations(mustHear: ["Export Notes", "Encrypt with a passphrase"])) { offscreen, exchange in
				exchange.isExporting = true
				await offscreen.pump { offscreen.sheet != nil }
			},
			library(catchesSheets: true, expecting: AuditExpectations(mustHear: ["Imported 3 notes."])) { offscreen, exchange in
				exchange.lastImport = ImportSummary(added: 3)
				await offscreen.pump { offscreen.sheet != nil }
			},
		]
	}
}

extension SecuritySettings {
	static func stubbed(touchIDAvailable: Bool = true, touchIDEnabled: Bool = false, status: AppModel.SyncStatus = AppModel.SyncStatus()) -> SecuritySettings {
		SecuritySettings(
			touchIDAvailable: touchIDAvailable,
			touchIDEnabled: touchIDEnabled,
			turnOnTouchID: { _ in nil },
			turnOffTouchID: { nil },
			changePassword: { _, _ in nil },
			sync: SyncControls(status: status)
		)
	}
}

extension OffscreenWindow {
	func enterPasswords(_ password: String, confirming confirmation: String) throws {
		try press("Next")
		try type(password, into: "Password")
		try submit(confirmation, in: "Confirm Password")
	}

	func reachTouchIDOffer() async throws {
		try enterPasswords("correct horse", confirming: "correct horse")
		await pump { button("Set Up Touch ID") != nil }
	}

	func enterServer() throws {
		try type("http://notes.example:8080", into: try #require(editableTextFields().first))
		try type("0a0b", into: try #require(views(of: NSSecureTextField.self).first))
		try press("Continue")
	}
}
