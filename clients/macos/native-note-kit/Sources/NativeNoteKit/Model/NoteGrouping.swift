import Foundation

nonisolated public struct NoteGroup: Identifiable, Equatable {
	public let title: String
	public let notes: [Note]

	public var id: String { title }
}

nonisolated public enum NoteGrouping {
	private enum Bucket {
		case today, yesterday, previousWeek, thisYear, earlier
	}

	private struct Boundaries {
		let calendar: Calendar
		let today: Date
		let yesterday: Date
		let weekAgo: Date
		let year: Int

		init(now: Date, calendar: Calendar) {
			self.calendar = calendar
			today = calendar.startOfDay(for: now)
			yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
			weekAgo = calendar.date(byAdding: .day, value: -7, to: today) ?? today
			year = calendar.component(.year, from: now)
		}

		func bucket(for date: Date) -> Bucket {
			if date >= today { return .today }
			if date >= yesterday { return .yesterday }
			if date >= weekAgo { return .previousWeek }
			return calendar.component(.year, from: date) == year ? .thisYear : .earlier
		}

		func title(for date: Date, months: [String]) -> String {
			switch bucket(for: date) {
			case .today: "Today"
			case .yesterday: "Yesterday"
			case .previousWeek: "Previous 7 days"
			case .thisYear: months[calendar.component(.month, from: date) - 1]
			case .earlier: String(calendar.component(.year, from: date))
			}
		}
	}

	static func groups(for notes: [Note], now: Date, calendar: Calendar = .current) -> [NoteGroup] {
		let boundaries = Boundaries(now: now, calendar: calendar)
		let months: [String] = monthNames.monthSymbols
		var grouped: [(title: String, notes: [Note])] = []
		for note in notes.sorted(by: { $0.updatedAt > $1.updatedAt }) {
			let title = boundaries.title(for: note.updated, months: months)
			if grouped.last?.title == title {
				grouped[grouped.count - 1].notes.append(note)
			} else {
				grouped.append((title, [note]))
			}
		}
		return grouped.map { NoteGroup(title: $0.title, notes: $0.notes) }
	}

	static func title(for date: Date, now: Date, calendar: Calendar = .current) -> String {
		Boundaries(now: now, calendar: calendar).title(for: date, months: monthNames.monthSymbols)
	}

	public static func dateLabel(for date: Date, now: Date, calendar: Calendar = .current) -> String {
		switch Boundaries(now: now, calendar: calendar).bucket(for: date) {
		case .today:
			date.formatted(
				Date.FormatStyle(
					date: .omitted,
					time: .shortened,
					locale: calendar.locale ?? .autoupdatingCurrent,
					calendar: calendar,
					timeZone: calendar.timeZone
				)
			)
		case .yesterday:
			"Yesterday"
		case .previousWeek:
			calendar.standaloneWeekdaySymbols[calendar.component(.weekday, from: date) - 1]
		case .thisYear, .earlier:
			date.formatted(
				Date.VerbatimFormatStyle(
					format: "\(year: .defaultDigits).\(month: .twoDigits).\(day: .twoDigits)",
					timeZone: calendar.timeZone,
					calendar: calendar
				)
			)
		}
	}

	private static let monthNames: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = .autoupdatingCurrent
		return formatter
	}()
}
