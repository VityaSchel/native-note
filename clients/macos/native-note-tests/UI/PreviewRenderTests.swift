import AppKit
import Foundation
import SwiftUI
import Testing

@testable import NativeNote
@testable import NativeNoteKit

@MainActor
private extension Screen {
	var showsSomething: Bool {
		let offscreen = OffscreenWindow(view, width: width, height: height)
		defer { offscreen.close() }
		return Self.showsSomething(in: offscreen)
	}

	static func showsSomething(in offscreen: OffscreenWindow<AnyView>) -> Bool {
		!offscreen.host.subviews.isEmpty || !offscreen.accessibilityElements().isEmpty
	}
}

@MainActor
struct PreviewRenderTests {
	@Test(arguments: ScreenGroup.allCases.filter { !$0.isDriven })
	private func everyPreviewRendersWithoutCrashingAndShowsSomething(_ preview: ScreenGroup) {
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
