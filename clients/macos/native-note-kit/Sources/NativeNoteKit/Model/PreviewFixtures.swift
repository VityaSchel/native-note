import Foundation

#if DEBUG
	extension Note {
		public static func sample(_ number: Int, _ body: String, minutesAgo: Int) -> Note {
			let moment = Date(timeIntervalSince1970: 1_786_000_000 - Double(minutesAgo) * 60)
			let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!
			return Note(id: id, body: body, createdAt: moment, updatedAt: moment)
		}
	}

	extension NoteGroup {
		public static let samples = [
			NoteGroup(
				title: "Today",
				notes: [
					.sample(1, "Shopping\nquartz, bread, and a new kettle", minutesAgo: 5),
					.sample(2, "Standup notes\nshipped the storage layer", minutesAgo: 90),
					.sample(3, "", minutesAgo: 200),
				]
			),
			NoteGroup(title: "Yesterday", notes: [.sample(4, "Reading list\nRFC 9106, then the SQLCipher design doc", minutesAgo: 1_500)]),
			NoteGroup(title: "July", notes: [.sample(5, "Trip plan\nferry at 07:20", minutesAgo: 40_000)]),
		]
	}
#endif
