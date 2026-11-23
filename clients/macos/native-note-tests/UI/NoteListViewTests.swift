import AppKit
import CoreText
import SwiftUI
import Testing

@testable import NativeNote
@testable import NativeNoteKit

@MainActor
private final class Deletions {
	var ids: [UUID] = []
}

@MainActor @Suite(.takesFocus)
struct NoteListViewTests {
	private func offscreen(selection: UUID?, _ deletions: Deletions) -> OffscreenWindow<NavigationStack<NavigationPath, NoteListView>> {
		OffscreenWindow(
			NavigationStack {
				NoteListView(groups: NoteGroup.samples, now: Note.sampleNow, selection: .constant(selection), search: .constant("")) { deletions.ids.append($0) }
			},
			width: 300,
			height: 460
		)
	}

	private func focusedList(in offscreen: OffscreenWindow<NavigationStack<NavigationPath, NoteListView>>) throws -> NSTableView {
		let table = try #require(offscreen.views(of: NSTableView.self).first)
		try #require(offscreen.window.makeFirstResponder(table))
		offscreen.pump()
		return table
	}

	private func pressBackspace(on list: NSTableView, in offscreen: OffscreenWindow<NavigationStack<NavigationPath, NoteListView>>) throws {
		let backspace = try #require(
			NSEvent.keyEvent(
				with: .keyDown,
				location: .zero,
				modifierFlags: [],
				timestamp: 0,
				windowNumber: offscreen.window.windowNumber,
				context: nil,
				characters: "\u{7F}",
				charactersIgnoringModifiers: "\u{7F}",
				isARepeat: false,
				keyCode: 51
			)
		)
		list.keyDown(with: backspace)
		offscreen.pump()
	}

	private func editMenuDeleteIsEnabled(from focused: NSResponder) -> Bool {
		let delete = #selector(NSText.delete(_:))
		var responder: NSResponder? = focused
		while let current = responder, !current.responds(to: delete) {
			responder = current.nextResponder
		}
		let item = NSMenuItem(title: "Delete", action: delete, keyEquivalent: "")
		return (responder as? NSUserInterfaceValidations)?.validateUserInterfaceItem(item) ?? false
	}

	@Test func rowsMatchAppleNotesMetrics() throws {
		let notes: [Note] = [.sample(1, "Shopping\nquartz, bread", minutesAgo: 5), .sample(2, "Standup\nshipped", minutesAgo: 90)]
		let offscreen = OffscreenWindow(
			NavigationStack {
				NoteListView(groups: [NoteGroup(title: "Today", notes: notes)], now: Note.sampleNow, selection: .constant(nil), search: .constant("")) { _ in }
			},
			width: 300,
			height: 260
		)
		defer { offscreen.close() }
		offscreen.window.appearance = NSAppearance(named: .aqua)
		offscreen.pump(for: 0.2)
		let list = try #require(offscreen.views(of: NSTableView.self).first)
		let row = list.convert(list.rect(ofRow: 1), to: offscreen.host)
		let rep = try #require(offscreen.host.bitmapImageRepForCachingDisplay(in: offscreen.host.bounds))
		offscreen.host.cacheDisplay(in: offscreen.host.bounds, to: rep)
		let scale = CGFloat(rep.pixelsWide) / offscreen.host.bounds.width
		let top = offscreen.host.isFlipped ? row.minY : offscreen.host.bounds.height - row.maxY
		var textLeft = CGFloat.infinity
		var inkTop = CGFloat.infinity
		for y in Int(top * scale) ..< Int((top + row.height) * scale) {
			for x in 0 ..< rep.pixelsWide where (rep.colorAt(x: x, y: y)?.brightnessComponent ?? 1) < 0.5 {
				textLeft = min(textLeft, CGFloat(x) / scale)
				inkTop = min(inkTop, CGFloat(y) / scale - top)
			}
		}

		#expect(list.rect(ofRow: 1).height == 56)
		#expect(list.rect(ofRow: 2).height == 56)
		#expect(abs(textLeft - 35) <= 1, "text starts \(textLeft) pt from the list edge")
		#expect(abs(inkTop - 15.8) <= 1.5, "the title's ink starts \(inkTop) pt below the row top")
	}

	private func rowHeights(of list: some View, width: CGFloat) throws -> [CGFloat] {
		let offscreen = OffscreenWindow(NavigationStack { list }, width: width, height: 400)
		defer { offscreen.close() }
		offscreen.pump(for: 0.2)
		let table = try #require(offscreen.views(of: NSTableView.self).first)
		return (0 ..< table.numberOfRows).map { table.rect(ofRow: $0).height }
	}

	@Test func theNarrowestListKeepsTheLongestDatesOnOneLine() throws {
		for calendar in LongestDateLabels.calendars {
			let (notes, now) = LongestDateLabels.notes(in: calendar)
			let list = NoteListView(groups: [NoteGroup(title: "Today", notes: notes)], now: now, selection: .constant(nil), search: .constant("")) { _ in }
				.environment(\.calendar, calendar)
			let labels = notes.map { NoteGrouping.dateLabel(for: $0.updated, now: now, calendar: calendar) }
			let wide = try rowHeights(of: list, width: 1_200)
			try #require(wide.count == notes.count + 1)

			#expect(try rowHeights(of: list, width: ContentView.narrowestList) == wide, "\(labels)")
		}
	}

	@Test func onlyNotesOfTheSameDayAreSeparated() {
		let notes: [Note] = [.sample(1, "a", minutesAgo: 1), .sample(2, "b", minutesAgo: 2), .sample(3, "c", minutesAgo: 3)]
		let group = NoteGroup(title: "Today", notes: notes)

		#expect(NoteListView.separatorsHidden(for: notes[0], in: group) == .top)
		#expect(NoteListView.separatorsHidden(for: notes[1], in: group) == [])
		#expect(NoteListView.separatorsHidden(for: notes[2], in: group) == .bottom)
		#expect(NoteListView.separatorsHidden(for: notes[0], in: NoteGroup(title: "Today", notes: [notes[0]])) == [.top, .bottom])
	}

	@Test func noSeparatorTouchesADayHeading() throws {
		let notes: [Note] = [.sample(1, "Shopping\nbread", minutesAgo: 5), .sample(2, "Standup\nshipped", minutesAgo: 90), .sample(3, "Reading\nRFC 9106", minutesAgo: 1_500)]
		let groups = [NoteGroup(title: "Today", notes: Array(notes.prefix(2))), NoteGroup(title: "Yesterday", notes: [notes[2]])]
		let offscreen = OffscreenWindow(
			NavigationStack { NoteListView(groups: groups, now: Note.sampleNow, selection: .constant(nil), search: .constant("")) { _ in } },
			width: 300,
			height: 300
		)
		defer { offscreen.close() }
		offscreen.window.appearance = NSAppearance(named: .aqua)
		offscreen.pump(for: 0.2)
		let list = try #require(offscreen.views(of: NSTableView.self).first)
		try #require(list.numberOfRows == 5)
		let rep = try #require(offscreen.host.bitmapImageRepForCachingDisplay(in: offscreen.host.bounds))
		offscreen.host.cacheDisplay(in: offscreen.host.bounds, to: rep)
		let scale = CGFloat(rep.pixelsWide) / offscreen.host.bounds.width
		func lineNear(_ y: CGFloat) -> Bool {
			(Int((y - 2) * scale) ... Int((y + 2) * scale)).contains { row in
				(Int(40 * scale) ..< Int(250 * scale)).filter { (rep.colorAt(x: $0, y: row)?.brightnessComponent ?? 1) < 0.97 }.count > Int(150 * scale)
			}
		}
		func edges(ofRow row: Int) -> (top: CGFloat, bottom: CGFloat) {
			let rect = list.convert(list.rect(ofRow: row), to: offscreen.host)
			return offscreen.host.isFlipped ? (rect.minY, rect.maxY) : (offscreen.host.bounds.height - rect.maxY, offscreen.host.bounds.height - rect.minY)
		}

		#expect(lineNear(edges(ofRow: 1).bottom), "notes of the same day keep their separator")
		#expect(!lineNear(edges(ofRow: 3).top), "no line above the Yesterday heading")
		#expect(!lineNear(edges(ofRow: 3).bottom), "no line under the Yesterday heading")
	}

	@Test func deleteRemovesTheSelectedNote() throws {
		let deletions = Deletions()
		let selected = NoteGroup.samples[0].notes[1].id
		let offscreen = offscreen(selection: selected, deletions)
		defer { offscreen.close() }
		let list = try focusedList(in: offscreen)

		#expect(editMenuDeleteIsEnabled(from: list))
		#expect(list.tryToPerform(#selector(NSText.delete(_:)), with: nil))
		try pressBackspace(on: list, in: offscreen)

		#expect(deletions.ids == [selected, selected])
	}

	@Test func deleteIsOffWithNothingSelected() throws {
		let deletions = Deletions()
		let offscreen = offscreen(selection: nil, deletions)
		defer { offscreen.close() }
		let list = try focusedList(in: offscreen)

		#expect(!editMenuDeleteIsEnabled(from: list))
		try pressBackspace(on: list, in: offscreen)

		#expect(deletions.ids.isEmpty)
	}

	@Test func rightClickingARowOffersToDeleteThatRow() throws {
		let deletions = Deletions()
		let offscreen = offscreen(selection: NoteGroup.samples[0].notes[0].id, deletions)
		defer { offscreen.close() }
		let list = try focusedList(in: offscreen)
		let row = list.rect(ofRow: list.numberOfRows - 1)
		let click = try #require(
			NSEvent.mouseEvent(
				with: .rightMouseDown,
				location: list.convert(NSPoint(x: row.midX, y: row.midY), to: nil),
				modifierFlags: [],
				timestamp: 0,
				windowNumber: offscreen.window.windowNumber,
				context: nil,
				eventNumber: 0,
				clickCount: 1,
				pressure: 1
			)
		)
		let menu = try #require(list.menu(for: click))

		#expect(menu.items.map(\.title) == ["Delete"])
		menu.performActionForItem(at: 0)
		offscreen.pump()

		#expect(deletions.ids == [NoteGroup.samples[2].notes[0].id])
	}

	@Test func anEmptyLibrarySaysThereAreNoNotes() {
		let list = NoteListView(groups: [], now: Note.sampleNow, selection: .constant(nil), search: .constant("")) { _ in }

		#expect(list.emptyState == .noNotes)
	}

	@Test func aSearchWithoutResultsSaysNoResults() {
		let list = NoteListView(groups: [], now: Note.sampleNow, selection: .constant(nil), search: .constant("kayak")) { _ in }

		#expect(list.emptyState == .noResults)
	}

	@Test func aListWithNotesShowsNoPlaceholder() {
		let list = NoteListView(groups: NoteGroup.samples, now: Note.sampleNow, selection: .constant(nil), search: .constant("kayak")) { _ in }

		#expect(list.emptyState == nil)
	}
}

@MainActor
private enum LongestDateLabels {
	private static let font = NoteRow.detailFont.resolve(in: EnvironmentValues().fontResolutionContext).ctFont
	private static let preview = "shipped the storage layer and the export format, then reviewed the plan"

	static var calendars: [Calendar] {
		let locales = Locale.availableIdentifiers.map(calendar(_:))
		let weekdays = locales.map { widestWeekday(in: $0).width }
		let times = locales.map(widestCommonTime(in:))
		return [.current, locales[weekdays.indices.max { weekdays[$0] < weekdays[$1] }!], locales[times.indices.max { times[$0] < times[$1] }!]]
	}

	static func notes(in calendar: Calendar) -> (notes: [Note], now: Date) {
		let weekday = widestWeekday(in: calendar).weekday
		var today = calendar.startOfDay(for: Note.sampleNow)
		while calendar.component(.weekday, from: day(-3, from: today, in: calendar)) != weekday {
			today = day(1, from: today, in: calendar)
		}
		let now = calendar.date(byAdding: .minute, value: 1_439, to: today)!
		let width = { (date: Date) in self.width(NoteGrouping.dateLabel(for: date, now: now, calendar: calendar)) }
		let minutes = (0 ..< 1_440).map { calendar.date(byAdding: .minute, value: $0, to: today)! }
		let older = (8 ... 800).map { day(-$0, from: today, in: calendar) }
		let dates = [minutes.max { width($0) < width($1) }!, day(-1, from: today, in: calendar), day(-3, from: today, in: calendar), older.max { width($0) < width($1) }!]
		let notes = dates.map { date in
			Note(id: UUID(), body: "Standup\n\(preview)", createdAt: date.epochMilliseconds, updatedAt: date.epochMilliseconds)
		}
		return (notes, now)
	}

	private static func calendar(_ identifier: String) -> Calendar {
		let locale = Locale(identifier: identifier)
		var calendar = locale.calendar
		calendar.locale = locale
		return calendar
	}

	private static func day(_ offset: Int, from date: Date, in calendar: Calendar) -> Date {
		calendar.date(byAdding: .day, value: offset, to: date)!
	}

	private static func width(_ label: String) -> CGFloat {
		CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [.font: font])), nil, nil, nil)
	}

	private static func widestWeekday(in calendar: Calendar) -> (weekday: Int, width: CGFloat) {
		calendar.standaloneWeekdaySymbols.enumerated().map { ($0 + 1, width($1)) }.max { $0.1 < $1.1 }!
	}

	private static func widestCommonTime(in calendar: Calendar) -> CGFloat {
		let today = calendar.startOfDay(for: Note.sampleNow)
		let now = calendar.date(byAdding: .minute, value: 1_439, to: today)!
		return [0, 10, 11, 12, 21, 22, 23].map { hour in
			width(NoteGrouping.dateLabel(for: calendar.date(byAdding: .minute, value: hour * 60 + 58, to: today)!, now: now, calendar: calendar))
		}.max()!
	}
}
