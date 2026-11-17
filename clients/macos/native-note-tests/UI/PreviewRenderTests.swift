import AppKit
import Foundation
import LocalAuthentication
import SwiftUI
import Testing

@testable import NativeNote
@testable import NativeNoteKit

@MainActor
private struct Screen {
	let view: AnyView
	let width: CGFloat
	let height: CGFloat

	init(_ view: some View, width: CGFloat = 380, height: CGFloat = 620) {
		self.view = AnyView(view)
		self.width = width
		self.height = height
	}

	var showsSomething: Bool {
		let offscreen = OffscreenWindow(view, width: width, height: height)
		defer { offscreen.close() }
		return Self.showsSomething(in: offscreen)
	}

	static func showsSomething(in offscreen: OffscreenWindow<AnyView>) -> Bool {
		!offscreen.host.subviews.isEmpty || !offscreen.accessibilityElements().isEmpty
	}
}

private enum Preview: String, CaseIterable, CustomTestStringConvertible {
	case unlockScreens, settingsScreens, noteRows, noteListWithSamples, noteListWithAnInitialSelection, noteListInsideASplitViewLikeTheApp
	case noteListEmpty, noteListWithoutMatches, editor, libraryShell, libraryShellWithNothingSelected, exchangeSheets, firstRunShell

	var testDescription: String { rawValue }

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
				Screen(SecuritySettings(touchIDAvailable: true, touchIDEnabled: true, turnOnTouchID: { _ in nil }, turnOffTouchID: {}, changePassword: { _, _ in nil }), width: 440, height: 300),
				Screen(SecuritySettings(touchIDAvailable: false, touchIDEnabled: false, turnOnTouchID: { _ in nil }, turnOffTouchID: {}, changePassword: { _, _ in nil }), width: 440, height: 300),
				Screen(ChangePasswordView(change: { _, _ in nil }, done: {}), width: 360, height: 300),
				Screen(TurnOnTouchIDView(turnOn: { _ in nil }, done: {}), width: 360, height: 160),
				Screen(SecuritySettings(touchIDAvailable: true, touchIDEnabled: false, turnOnTouchID: { _ in nil }, turnOffTouchID: {}, changePassword: { _, _ in nil }, sync: SyncControls(status: status)), width: 440, height: 520),
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
		}
	}
}

@MainActor
struct PreviewRenderTests {
	@Test(arguments: Preview.allCases)
	private func everyPreviewRendersWithoutCrashingAndShowsSomething(_ preview: Preview) {
		let screens = preview.screens

		#expect(!screens.isEmpty)
		for (index, screen) in screens.enumerated() {
			#expect(screen.showsSomething, "\(preview) screen \(index + 1)")
		}
	}

	@Test func listSurvivesIdentityChurnWhileSelectionPersists() {
		func freshGroups() -> [NoteGroup] {
			[
				NoteGroup(title: "Today", notes: [.sample(1, "Shopping\nbread", minutesAgo: 1), .sample(2, "", minutesAgo: 2)]),
				NoteGroup(title: "Yesterday", notes: [.sample(3, "Reading\nRFC 9106", minutesAgo: 1_500)]),
			]
		}
		func list(_ groups: [NoteGroup], selection: UUID) -> AnyView {
			AnyView(NavigationStack { NoteListView(groups: groups, now: Note.sampleNow, selection: .constant(selection), search: .constant("")) { _ in } })
		}

		let first = freshGroups()
		let staleSelection = first[0].notes[0].id
		let offscreen = OffscreenWindow(list(first, selection: staleSelection))
		defer { offscreen.close() }

		for _ in 0 ..< 3 {
			offscreen.host.rootView = list(freshGroups(), selection: staleSelection)
			offscreen.pump(for: 0.05)
		}

		#expect(Screen.showsSomething(in: offscreen))
	}

	@Test func listToleratesASelectionThatIsNotInTheList() {
		let list = NavigationStack {
			NoteListView(groups: NoteGroup.samples, now: Note.sampleNow, selection: .constant(UUID()), search: .constant("")) { _ in }
		}

		#expect(Screen(list).showsSomething)
	}
}
