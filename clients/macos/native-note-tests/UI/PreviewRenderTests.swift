import AppKit
import Foundation
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
		render(UnlockView(isSetup: false, failure: nil, submit: { _ in }, dismissFailure: {}))
		render(UnlockView(isSetup: false, failure: .wrongPassword, submit: { _ in }, dismissFailure: {}))
		render(UnlockView(isSetup: true, failure: nil, submit: { _ in }, dismissFailure: {}))
		render(UnlockView(isSetup: false, failure: nil, submit: { _ in }, dismissFailure: {}, unlockWithBiometrics: {}))
		render(UnlockView(isSetup: false, failure: .wrongPassword, submit: { _ in }, dismissFailure: {}, eraseLibrary: {}))
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
				NoteListView(groups: NoteGroup.samples, selection: .constant(nil), search: .constant(""))
			}
		)
	}

	@Test func noteListWithAnInitialSelection() {
		render(
			NavigationStack {
				NoteListView(
					groups: NoteGroup.samples,
					selection: .constant(NoteGroup.samples[0].notes[0].id),
					search: .constant("")
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
					selection: .constant(NoteGroup.samples[0].notes[0].id),
					search: .constant("")
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
					NoteListView(groups: first, selection: .constant(staleSelection), search: .constant(""))
				}
			)
		)

		for _ in 0 ..< 3 {
			offscreen.host.rootView = AnyView(
				NavigationStack {
					NoteListView(groups: freshGroups(), selection: .constant(staleSelection), search: .constant(""))
				}
			)
			offscreen.pump(for: 0.05)
		}
		offscreen.close()
	}

	@Test func listToleratesASelectionThatIsNotInTheList() {
		render(
			NavigationStack {
				NoteListView(groups: NoteGroup.samples, selection: .constant(UUID()), search: .constant(""))
			}
		)
	}

	@Test func noteListEmpty() {
		render(
			NavigationStack {
				NoteListView(groups: [], selection: .constant(nil), search: .constant(""))
			}
		)
	}

	@Test func noteListWithoutMatches() {
		render(
			NavigationStack {
				NoteListView(groups: [], selection: .constant(nil), search: .constant("kayak"))
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
