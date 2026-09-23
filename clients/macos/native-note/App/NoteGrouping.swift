import Foundation

nonisolated struct NoteGroup: Identifiable, Equatable {
	let title: String
	let notes: [Note]

	var id: String { title }
}

nonisolated enum NoteGrouping {
	static func groups(for notes: [Note], now: Date, calendar: Calendar = .current) -> [NoteGroup] {
		var grouped: [(title: String, notes: [Note])] = []
		for note in notes.sorted(by: { $0.updatedAt > $1.updatedAt }) {
			let title = title(for: note.updatedAt, now: now, calendar: calendar)
			if grouped.last?.title == title {
				grouped[grouped.count - 1].notes.append(note)
			} else {
				grouped.append((title, [note]))
			}
		}
		return grouped.map { NoteGroup(title: $0.title, notes: $0.notes) }
	}

	static func title(for date: Date, now: Date, calendar: Calendar = .current) -> String {
		let startOfToday = calendar.startOfDay(for: now)
		if date >= startOfToday { return "Today" }

		if let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday), date >= yesterday {
			return "Yesterday"
		}

		if let weekAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday), date >= weekAgo {
			return "Previous 7 days"
		}

		let year = calendar.component(.year, from: date)
		guard year == calendar.component(.year, from: now) else { return String(year) }

		return monthNames.monthSymbols[calendar.component(.month, from: date) - 1]
	}

	private static let monthNames: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = .autoupdatingCurrent
		return formatter
	}()
}
