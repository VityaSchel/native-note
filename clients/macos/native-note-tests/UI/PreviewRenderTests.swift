import AppKit
import Foundation
import LocalAuthentication
import SwiftUI
import Testing

@testable import NativeNote
@testable import NativeNoteKit

@MainActor
private func render(_ view: some View, width: CGFloat = 380, height: CGFloat = 620) {
	OffscreenWindow(view, width: width, height: height).close()
}

@MainActor
struct PreviewRenderTests {
	@Test func unlockScreens() {
		render(UnlockView(isSetup: false, failure: nil, submit: { _ in nil }, dismissFailure: {}))
		render(UnlockView(isSetup: false, failure: .wrongPassword, submit: { _ in nil }, dismissFailure: {}))
		render(UnlockView(isSetup: true, failure: nil, submit: { _ in nil }, dismissFailure: {}))
		for state in [AppModel.TouchID.listening(LAContext()), .paused(.inBackground), .paused(.checkingPassword), .paused(.shaking), .needsClick(after: .cancel), .lockedOut, .working] {
			render(UnlockView(isSetup: false, failure: nil, submit: { _ in nil }, dismissFailure: {}, touchID: TouchIDControls(state: state), eraseLibrary: {}))
		}
		render(UnlockView(isSetup: false, failure: nil, submit: { _ in nil }, dismissFailure: {}, touchID: TouchIDControls(state: .paused(.shaking)), shake: AppModel.Shake(count: 1, isRunning: true), eraseLibrary: {}))
		render(UnlockView(isSetup: false, failure: .wrongPassword, submit: { _ in nil }, dismissFailure: {}, eraseLibrary: {}))
		render(UnlockView(isSetup: true, failure: nil, submit: { _ in nil }, dismissFailure: {}, hasSecureEnclave: false))
	}

	@Test func settingsScreens() {
		render(SettingsView(model: .previewingFirstRun), width: 440, height: 300)
		render(SettingsView(model: .previewing([])), width: 440, height: 300)
		render(SecuritySettings(touchIDAvailable: true, touchIDEnabled: true, turnOnTouchID: { _ in nil }, turnOffTouchID: {}, changePassword: { _, _ in nil }), width: 440, height: 300)
		render(SecuritySettings(touchIDAvailable: false, touchIDEnabled: false, turnOnTouchID: { _ in nil }, turnOffTouchID: {}, changePassword: { _, _ in nil }), width: 440, height: 300)
		render(ChangePasswordView(turnsTouchIDOff: true, change: { _, _ in nil }, done: {}), width: 360, height: 300)
		render(TurnOnTouchIDView(turnOn: { _ in nil }, done: {}), width: 360, height: 160)
	}

	@Test func noteRows() {
		render(
			List {
				ZStack(alignment: .leading) { NoteRow(note: .sample(1, "Shopping\nquartz, bread, and a new kettle", minutesAgo: 5), now: Note.sampleNow) }
				ZStack(alignment: .leading) { NoteRow(note: .sample(3, "", minutesAgo: 200), now: Note.sampleNow) }
			}
		)
	}

	@Test func noteListWithSamples() {
		render(
			NavigationStack {
				NoteListView(groups: NoteGroup.samples, now: Note.sampleNow, selection: .constant(nil), search: .constant("")) { _ in }
			}
		)
	}

	@Test func noteListWithAnInitialSelection() {
		render(
			NavigationStack {
				NoteListView(
					groups: NoteGroup.samples,
					now: Note.sampleNow,
					selection: .constant(NoteGroup.samples[0].notes[0].id),
					search: .constant(""),
					delete: { _ in }
				)
			}
		)
	}

	@Test func noteListInsideASplitViewLikeTheApp() {
		render(
			NavigationSplitView {
				List { Label("All notes", systemImage: "tray.full") }
			} content: {
				NoteListView(
					groups: NoteGroup.samples,
					now: Note.sampleNow,
					selection: .constant(NoteGroup.samples[0].notes[0].id),
					search: .constant(""),
					delete: { _ in }
				)
			} detail: {
				Text("detail")
			},
			width: 980,
			height: 560
		)
	}

	@Test func listSurvivesIdentityChurnWhileSelectionPersists() {
		func freshGroups() -> [NoteGroup] {
			[
				NoteGroup(title: "Today", notes: [.sample(1, "Shopping\nbread", minutesAgo: 1), .sample(2, "", minutesAgo: 2)]),
				NoteGroup(title: "Yesterday", notes: [.sample(3, "Reading\nRFC 9106", minutesAgo: 1_500)]),
			]
		}

		let first = freshGroups()
		let staleSelection = first[0].notes[0].id
		let offscreen = OffscreenWindow(
			AnyView(
				NavigationStack {
					NoteListView(groups: first, now: Note.sampleNow, selection: .constant(staleSelection), search: .constant("")) { _ in }
				}
			)
		)

		for _ in 0 ..< 3 {
			offscreen.host.rootView = AnyView(
				NavigationStack {
					NoteListView(groups: freshGroups(), now: Note.sampleNow, selection: .constant(staleSelection), search: .constant("")) { _ in }
				}
			)
			offscreen.pump(for: 0.05)
		}
		offscreen.close()
	}

	@Test func listToleratesASelectionThatIsNotInTheList() {
		render(
			NavigationStack {
				NoteListView(groups: NoteGroup.samples, now: Note.sampleNow, selection: .constant(UUID()), search: .constant("")) { _ in }
			}
		)
	}

	@Test func noteListEmpty() {
		render(
			NavigationStack {
				NoteListView(groups: [], now: Note.sampleNow, selection: .constant(nil), search: .constant("")) { _ in }
			}
		)
	}

	@Test func noteListWithoutMatches() {
		render(
			NavigationStack {
				NoteListView(groups: [], now: Note.sampleNow, selection: .constant(nil), search: .constant("kayak")) { _ in }
			}
		)
	}

	@Test func editor() {
		render(NoteEditor(text: .constant("Shopping\n\nquartz and bread")))
		render(NoteEditor(text: .constant("")))
	}

	@Test func libraryShell() {
		render(
			ContentView(exchange: LibraryExchange(model: .previewing(NoteGroup.samples.flatMap(\.notes)))),
			width: 980,
			height: 560
		)
	}

	@Test func libraryShellWithNothingSelected() {
		let model = AppModel.previewing(NoteGroup.samples.flatMap(\.notes))
		model.selection = nil

		render(ContentView(exchange: LibraryExchange(model: model)), width: 980, height: 560)
	}

	@Test func exchangeSheets() {
		let notes = NoteGroup.samples.flatMap(\.notes)
		var theirs = notes[0]
		theirs.body = "Shopping\nonly bread"
		render(ExportSheet(export: { _ in }, cancel: {}))
		render(ImportPassphraseSheet(refused: true, working: false, submit: { _ in }, cancel: {}))
		render(ImportPassphraseSheet(refused: false, working: true, submit: { _ in }, cancel: {}))
		render(ConflictSheet(conflicts: [NoteConflict(mine: notes[0], theirs: theirs)], resolve: { _, _ in }), width: 560, height: 420)
	}

	@Test func firstRunShell() {
		render(ContentView(exchange: LibraryExchange(model: .previewingFirstRun)))
	}
}
