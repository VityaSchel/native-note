import AppKit
import SwiftUI
import Testing

@testable import NativeNote

@MainActor
private func render(_ view: some View, width: CGFloat = 380, height: CGFloat = 620) {
	let window = NSWindow(
		contentRect: NSRect(x: 0, y: 0, width: width, height: height),
		styleMask: [.titled],
		backing: .buffered,
		defer: false
	)
	let host = NSHostingView(rootView: view)
	host.frame = NSRect(x: 0, y: 0, width: width, height: height)
	window.contentView = host
	window.layoutIfNeeded()
	host.layoutSubtreeIfNeeded()
	host.displayIfNeeded()
	RunLoop.current.run(until: Date().addingTimeInterval(0.05))
	window.contentView = nil
}

@MainActor
struct PreviewRenderTests {
	@Test func unlockScreens() {
		render(UnlockView(isSetup: false, failure: nil, submit: { _ in }, dismissFailure: {}))
		render(UnlockView(isSetup: false, failure: .wrongPassword, submit: { _ in }, dismissFailure: {}))
		render(UnlockView(isSetup: true, failure: nil, submit: { _ in }, dismissFailure: {}))
		render(
			UnlockView(
				isSetup: false,
				failure: .unexpected("The notes database could not be opened."),
				submit: { _ in },
				dismissFailure: {}
			)
		)
		render(UnlockView(isSetup: false, failure: .unsaved("disk I/O error"), submit: { _ in }, dismissFailure: {}))
	}

	@Test func noteRows() {
		render(
			List {
				ZStack(alignment: .leading) { NoteRow(note: .sample(1, "Shopping\nquartz, bread, and a new kettle", minutesAgo: 5)) }
				ZStack(alignment: .leading) { NoteRow(note: .sample(3, "", minutesAgo: 200)) }
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
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 380, height: 620),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		let host = NSHostingView(
			rootView: AnyView(
				NavigationStack {
					NoteListView(groups: first, selection: .constant(staleSelection), search: .constant(""))
				}
			)
		)
		host.frame = NSRect(x: 0, y: 0, width: 380, height: 620)
		window.contentView = host
		host.layoutSubtreeIfNeeded()
		RunLoop.current.run(until: Date().addingTimeInterval(0.05))

		for _ in 0 ..< 3 {
			host.rootView = AnyView(
				NavigationStack {
					NoteListView(groups: freshGroups(), selection: .constant(staleSelection), search: .constant(""))
				}
			)
			host.layoutSubtreeIfNeeded()
			RunLoop.current.run(until: Date().addingTimeInterval(0.05))
		}
		window.contentView = nil
	}

	@Test func groupTitlesStayUniqueForAdversarialDates() {
		let calendar = Calendar(identifier: .gregorian)
		let now = Date()
		let offsets = [-86_400 * 400, -86_400 * 40, -86_400 * 8, -86_400 * 3, -3_600, 0, 3_600, 86_400, 86_400 * 90]
		let notes = offsets.enumerated().map { index, offset in
			Note.sample(index + 100, "note \(index)", minutesAgo: 0).movedTo(now.addingTimeInterval(Double(offset)))
		}

		let titles = NoteGrouping.groups(for: notes, now: now, calendar: calendar).map(\.title)

		#expect(Set(titles).count == titles.count, "duplicate section titles: \(titles)")
	}

	@Test func groupsAreIdenticalAcrossRepeatedReads() {
		let model = AppModel.previewing(NoteGroup.samples.flatMap(\.notes))
		let first = model.groups

		for _ in 0 ..< 200 {
			#expect(model.groups == first)
		}
	}

	@Test func sampleNotesHaveDistinctIdentities() {
		let notes = NoteGroup.samples.flatMap(\.notes)

		#expect(Set(notes.map(\.id)).count == notes.count)
		#expect(Set(NoteGroup.samples.map(\.id)).count == NoteGroup.samples.count)
	}

	@Test func listToleratesASelectionThatIsNotInTheList() {
		render(
			NavigationStack {
				NoteListView(groups: NoteGroup.samples, selection: .constant(UUID()), search: .constant(""))
			}
		)
	}

	@Test func previewingModelCreateNoteLeavesSelectionConsistent() async {
		let model = AppModel.previewing(NoteGroup.samples.flatMap(\.notes))

		await model.createNote()

		let visible = Set(model.groups.flatMap(\.notes).map(\.id))
		#expect(model.selection == nil || visible.contains(model.selection!))
	}

	@Test func noteListEmpty() {
		render(
			NavigationStack {
				NoteListView(groups: [], selection: .constant(nil), search: .constant(""))
			}
		)
	}

	@Test func editor() {
		render(NoteEditor(text: .constant("Shopping\n\nquartz and bread")))
		render(NoteEditor(text: .constant("")))
	}

	@Test func libraryShell() {
		render(
			ContentView(model: .previewing(NoteGroup.samples.flatMap(\.notes))),
			width: 980,
			height: 560
		)
	}

	@Test func libraryShellWithEditsNotSaved() {
		render(
			ContentView(model: .previewing(NoteGroup.samples.flatMap(\.notes), failure: .unsaved("disk I/O error"))),
			width: 980,
			height: 560
		)
	}

	@Test func firstRunShell() {
		render(ContentView(model: AppModel(directory: URL(fileURLWithPath: "/dev/null"))))
	}
}
