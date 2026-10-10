import Foundation
import Testing

@testable import NativeNoteKit

private let validFields = [
	"id: 3f2504e0-4f89-41d3-9a0c-0305e82c3301",
	"created: 2026-09-24T21:00:00.123Z",
	"updated: 2026-09-25T08:30:15.456Z",
	"v: 7",
]

private let textsWithoutFrontMatter: [String] = {
	let fieldLines = validFields.joined(separator: "\n")
	return [
		"",
		"Just a note",
		"---",
		"----\n\(fieldLines)\n---\nBody",
		" ---\n\(fieldLines)\n---\nBody",
		"\u{FEFF}---\n\(fieldLines)\n---\nBody",
		"---\r\n\(validFields.joined(separator: "\r\n"))\r\n---\r\nBody",
		"---\n\(fieldLines)\nBody without a closing line",
		"---\n\(fieldLines)\n---",
	]
}()

private func note(_ body: String, created: Int64 = 1_790_283_600_123, updated: Int64 = 1_790_325_015_456, v: UInt32 = 0) -> Note {
	Note(id: UUID(), body: body, createdAt: Date(epochMilliseconds: created), updatedAt: Date(epochMilliseconds: updated), v: v)
}

private func document(_ fields: [String]) -> String {
	"---\n" + fields.map { $0 + "\n" }.joined() + "---\nBody"
}

private func fileNames(_ titles: [String]) -> [String] {
	NoteMarkdown.fileNames(for: titles.enumerated().map { note($1 + "\nsecond line", created: Int64($0)) })
}

private func utf8(_ strings: [String]) -> [[UInt8]] {
	strings.map { Array($0.utf8) }
}

struct NoteMarkdownTests {
	@Test func importedNotesAreLiveDirtyAndUnsequenced() throws {
		var original = note("Synced elsewhere", v: 12)
		original.deleted = true
		original.dirty = false
		original.seq = 42

		let parsed = try NoteMarkdown.parse(NoteMarkdown.render(original))

		#expect(parsed.deleted == false)
		#expect(parsed.dirty)
		#expect(parsed.seq == nil)
		#expect(parsed.v == 12)
	}

	@Test(arguments: [
		"",
		"\n",
		"\n\nStarts after blank lines",
		"Ends with blank lines\n\n",
		"Windows\r\nline endings\r\n",
		"\r",
		"Old Mac\rline endings",
		"---",
		"---\n",
		"Above\n---\nBelow\n---\n",
		"---\nid: 00000000-0000-0000-0000-000000000000\ncreated: 1970-01-01T00:00:00.000Z\nupdated: 1970-01-01T00:00:00.000Z\nv: 0\n---\nA note inside a note",
		"id: 3f2504e0-4f89-41d3-9a0c-0305e82c3301\n---\n",
		"\u{301}Combining mark first",
		"Cafe\u{301} decomposed beside Caf\u{E9} precomposed",
		"日本語 👨‍👩‍👧‍👦 🇺🇦 ﷽",
		"\u{FEFF}Byte order mark",
		"Nul\u{0}byte, \u{2028}line separator, \u{85}next line",
		"  \t indented\t  ",
	])
	func bodiesRoundTripByteForByte(body: String) throws {
		let original = note(body, v: 3)

		let rendered = NoteMarkdown.render(original)
		let parsed = try NoteMarkdown.parse(rendered)

		#expect(Array(parsed.body.utf8) == Array(body.utf8))
		#expect(parsed.id == original.id)
		#expect(Array(NoteMarkdown.render(parsed).utf8) == Array(rendered.utf8))
	}

	@Test(arguments: [
		(Int64(0), "1970-01-01T00:00:00.000Z"),
		(1, "1970-01-01T00:00:00.001Z"),
		(-1, "1969-12-31T23:59:59.999Z"),
		(-1_001, "1969-12-31T23:59:58.999Z"),
		(1_760_000_000_123, "2025-10-09T08:53:20.123Z"),
		(951_782_400_000, "2000-02-29T00:00:00.000Z"),
		(-2_208_988_800_000, "1900-01-01T00:00:00.000Z"),
		(-62_135_596_800_000, "0001-01-01T00:00:00.000Z"),
		(-62_167_219_200_000, "0000-01-01T00:00:00.000Z"),
		(-62_167_219_200_001, "-000001-12-31T23:59:59.999Z"),
		(253_402_300_799_999, "9999-12-31T23:59:59.999Z"),
		(253_402_300_800_000, "+010000-01-01T00:00:00.000Z"),
		(8_640_000_000_000_000, "+275760-09-13T00:00:00.000Z"),
		(-8_640_000_000_000_000, "-271821-04-20T00:00:00.000Z"),
		(31_494_784_780_799_000, "+999999-12-31T23:59:59.000Z"),
		(.min, "-292275055-05-16T16:47:04.192Z"),
	])
	func timestampsKeepEveryMillisecond(milliseconds: Int64, expected: String) throws {
		let rendered = NoteMarkdown.render(note("Timed", created: milliseconds, updated: milliseconds))

		#expect(rendered.contains("\ncreated: \(expected)\nupdated: \(expected)\n"))

		let parsed = try NoteMarkdown.parse(rendered)
		#expect(parsed.createdAt.epochMilliseconds == milliseconds)
		#expect(parsed.updatedAt.epochMilliseconds == milliseconds)
	}

	@Test(arguments: [Int64(4_398_996_285_164_484), -4_399_850_991_844_399, 8_639_999_999_999_999, -8_639_999_999_999_999])
	func reimportsTimestampsBeyondTheMillisecondPrecisionOfDate(milliseconds: Int64) throws {
		let original = note("Far", created: milliseconds, updated: milliseconds)

		let parsed = try NoteMarkdown.parse(NoteMarkdown.render(original))

		#expect(abs(parsed.createdAt.timeIntervalSince(original.createdAt)) < 0.002)
		#expect(abs(parsed.updatedAt.timeIntervalSince(original.updatedAt)) < 0.002)
	}

	@Test(arguments: textsWithoutFrontMatter)
	func rejectsTextWithoutFrontMatter(text: String) {
		#expect(throws: NoteMarkdown.Failure.noFrontMatter) {
			try NoteMarkdown.parse(text)
		}
	}

	@Test(arguments: ["id", "created", "updated", "v"])
	func namesTheMissingField(name: String) {
		#expect(throws: NoteMarkdown.Failure.missingField(name)) {
			try NoteMarkdown.parse(document(validFields.filter { !$0.hasPrefix(name + ": ") }))
		}
	}

	@Test func anEmptyFrontMatterIsMissingTheID() {
		#expect(throws: NoteMarkdown.Failure.missingField("id")) {
			try NoteMarkdown.parse("---\n---\nBody")
		}
	}

	@Test(arguments: [
		("id", "id: 3F2504E0-4F89-41D3-9A0C-0305E82C3301"),
		("id", "id: {3f2504e0-4f89-41d3-9a0c-0305e82c3301}"),
		("id", "id: 3f2504e04f8941d39a0c0305e82c3301"),
		("id", "id:3f2504e0-4f89-41d3-9a0c-0305e82c3301"),
		("id", "id:  3f2504e0-4f89-41d3-9a0c-0305e82c3301"),
		("id", "id: "),
		("id", "id:"),
		("id", "id:x3f2504e0-4f89-41d3-9a0c-0305e82c3301"),
		("created", "created: 2026-09-24T21:00:00Z"),
		("created", "created: 2026-09-24T21:00:00.1234Z"),
		("created", "created: 2026-09-24T21:00:00.123+00:00"),
		("created", "created: 2026-09-24 21:00:00.123Z"),
		("created", "created: 2026-09-24t21:00:00.123z"),
		("created", "created: 2026-02-29T21:00:00.123Z"),
		("created", "created: 2026-13-01T00:00:00.000Z"),
		("created", "created: 2026-09-24T24:00:00.000Z"),
		("created", "created: 2026-12-31T23:59:60.000Z"),
		("created", "created: +002026-09-24T21:00:00.123Z"),
		("created", "created: 002026-09-24T21:00:00.123Z"),
		("created", "created: -000000-01-01T00:00:00.000Z"),
		("created", "created: +0999999-12-31T23:59:59.000Z"),
		("created", "created: +292278994-08-17T07:12:55.807Z"),
		("created", "created: +292278994-08-17T07:12:55.808Z"),
		("created", "created: +1000000000-01-01T00:00:00.000Z"),
		("created", "created:X2026-09-24T21:00:00.123Z"),
		("updated", "updated: 1790325015456"),
		("updated", "updated: 2026-09-25T08:30:15.456Z\r"),
		("v", "v: -1"),
		("v", "v: +7"),
		("v", "v: 07"),
		("v", "v: 4294967296"),
		("v", "v: 7 "),
		("v", "v:7"),
		("v", "v:77"),
		("v", "v: seven"),
		("v", "v: \u{301}7"),
	])
	func namesTheInvalidField(name: String, line: String) {
		#expect(throws: NoteMarkdown.Failure.invalidField(name)) {
			try NoteMarkdown.parse(document(validFields.map { $0.hasPrefix(name + ": ") ? line : $0 }))
		}
	}

	@Test(arguments: ["id", "created", "updated", "v"])
	func namesTheDuplicateField(name: String) {
		let repeated = validFields.flatMap { $0.hasPrefix(name + ": ") ? [$0, $0] : [$0] }

		#expect(throws: NoteMarkdown.Failure.duplicateField(name)) {
			try NoteMarkdown.parse(document(repeated))
		}
	}

	@Test(arguments: [
		("title: Groceries", "title"),
		("deleted: false", "deleted"),
		("ID: 3f2504e0-4f89-41d3-9a0c-0305e82c3301", "ID"),
		("", ""),
		("# comment", "# comment"),
	])
	func namesTheUnknownField(line: String, name: String) {
		var lines = validFields
		lines.insert(line, at: 1)

		#expect(throws: NoteMarkdown.Failure.unknownField(name)) {
			try NoteMarkdown.parse(document(lines))
		}
	}

	@Test func namesAFieldThatIsOutOfOrder() {
		#expect(throws: NoteMarkdown.Failure.misplacedField("id")) {
			try NoteMarkdown.parse(document([validFields[1], validFields[0], validFields[2], validFields[3]]))
		}
		#expect(throws: NoteMarkdown.Failure.misplacedField("updated")) {
			try NoteMarkdown.parse(document([validFields[0], validFields[1], validFields[3], validFields[2]]))
		}
	}

	@Test func namesEachFileAfterItsTitle() {
		#expect(fileNames(["Groceries", "  Trip to Lviv  "]) == ["Groceries.md", "Trip to Lviv.md"])
		#expect(NoteMarkdown.fileNames(for: []).isEmpty)
	}

	@Test(arguments: [
		("a/b\\c:d|e", "a-b-c-d-e"),
		("2026/09/24", "2026-09-24"),
		("What? *Really* \"quoted\" <tag>", "What Really quoted tag"),
		("Tab\tseparated", "Tab separated"),
		("Nul\u{0}escape\u{1B}delete\u{7F}csi\u{9B}end", "Nul escape delete csi end"),
		("...hidden", "hidden"),
		(". . .spaced dots", "spaced dots"),
		("\u{0}.leading control", "leading control"),
		("Trailing dots...", "Trailing dots"),
		("Trailing mix . .", "Trailing mix"),
		("v1.2 release notes", "v1.2 release notes"),
		("CON", "_CON"),
		("con.backup", "_con.backup"),
		("Aux .txt", "_Aux .txt"),
		("lpt9", "_lpt9"),
		("COM¹", "_COM¹"),
		("Console", "Console"),
		("NULL", "NULL"),
		("Cafe\u{301}", "Caf\u{E9}"),
	])
	func replacesCharactersThatAreUnsafeInFileNames(title: String, expected: String) {
		#expect(utf8(fileNames([title])) == utf8([expected + ".md"]))
	}

	@Test func prefixesAWindowsReservedNameThatTheCapReveals() {
		let spaces = String(repeating: " ", count: 246)
		let dots = String(repeating: ".", count: 250)

		#expect(fileNames(["CON" + spaces + "x"]) == ["_CON.md"])
		#expect(fileNames(["aux" + spaces + "    tail"]) == ["_aux.md"])
		#expect(fileNames(["NUL" + dots + "x"]) == ["_NUL.md"])
		#expect(fileNames(["lpt1" + spaces + "x.txt"]) == ["_lpt1.md"])
	}

	@Test(arguments: ["", "   ", "\t\u{3000}", "...", "?*<>\"", "\u{0}\u{1}\u{7F}", " . . "])
	func namesAFileUntitledWhenTheTitleLeavesNothing(title: String) {
		#expect(fileNames([title]) == ["Untitled.md"])
	}

	@Test func numbersUntitledNotes() {
		#expect(NoteMarkdown.fileNames(for: [note("", created: 0), note("\n\nbody", created: 1), note("???", created: 2)]) == [
			"Untitled.md", "Untitled 2.md", "Untitled 3.md",
		])
	}

	@Test func numbersThousandsOfUntitledNotesInSequence() {
		let names = fileNames(Array(repeating: "", count: 3_000))

		#expect(names.first == "Untitled.md")
		#expect(Array(names.dropFirst()) == (2...3_000).map { "Untitled \($0).md" })
	}

	@Test func capsLongTitlesWithoutSplittingAGraphemeCluster() {
		let family = "👨‍👩‍👧‍👦"
		let stacked = "x\u{301}\u{302}"
		let a = { (count: Int) in String(repeating: "a", count: count) }

		#expect(family.utf8.count == 25)
		#expect(utf8(fileNames([String(repeating: family, count: 20)])) == utf8([String(repeating: family, count: 9) + ".md"]))
		#expect(utf8(fileNames([String(repeating: stacked, count: 60)])) == utf8([String(repeating: stacked, count: 49) + ".md"]))
		#expect(utf8(fileNames([a(247) + family])) == utf8([a(247) + ".md"]))
		#expect(utf8(fileNames([a(246) + "\u{E9}b"])) == utf8([a(246) + "\u{E9}.md"]))
		#expect(utf8(fileNames([a(246) + "e\u{301}b"])) == utf8([a(246) + "\u{E9}.md"]))
		#expect(utf8(fileNames([a(247) + "\u{E9}"])) == utf8([a(247) + ".md"]))
		#expect(fileNames([a(247) + " b"]) == [a(247) + ".md"])
		#expect(fileNames([a(246) + ". b"]) == [a(246) + ".md"])
	}

	@Test func aSingleClusterLongerThanTheCapIsUntitled() {
		#expect(fileNames(["x" + String(repeating: "\u{301}", count: 200)]) == ["Untitled.md"])
	}

	@Test func leavesRoomForTwoDigitNumbersAndKeepsEveryNameUnder255Bytes() {
		let names = fileNames(Array(repeating: String(repeating: "a", count: 300), count: 120))
		let capped = String(repeating: "a", count: 248)

		#expect(names[0] == capped + ".md")
		#expect(names[1] == capped + " 2.md")
		#expect(names[98] == capped + " 99.md")
		#expect(names[98].utf8.count == 254)
		#expect(names[99] == String(repeating: "a", count: 247) + " 100.md")
		#expect(names.allSatisfy { $0.utf8.count < 255 })
		#expect(Set(names).count == names.count)
	}

	@Test func titlesThatMatchOnlyBeyondTheCapAreNumbered() {
		let capped = String(repeating: "a", count: 248)

		#expect(fileNames([capped + "X", capped + "Y"]) == [capped + ".md", capped + " 2.md"])
	}

	@Test func numbersNamesThatDifferOnlyInCase() {
		#expect(fileNames(["Note", "note", "NOTE"]) == ["Note.md", "note 2.md", "NOTE 3.md"])
	}

	@Test func numbersNamesThatDifferOnlyInUnicodeNormalization() {
		#expect(
			utf8(fileNames(["Caf\u{E9}", "Cafe\u{301}", "CAFE\u{301}", "caf\u{C9}"]))
				== utf8(["Caf\u{E9}.md", "Caf\u{E9} 2.md", "CAF\u{C9} 3.md", "caf\u{C9} 4.md"])
		)
	}

	@Test func numbersNamesThatMatchUnderFullCaseFolding() {
		#expect(fileNames(["Straße", "STRASSE", "ΟΔΟΣ", "οδος"]) == ["Straße.md", "STRASSE 2.md", "ΟΔΟΣ.md", "οδος 2.md"])
	}

	@Test func numbersTitlesThatBecomeTheSameName() {
		#expect(fileNames(["a/b", "a:b", "a-b", ".a-b."]) == ["a-b.md", "a-b 2.md", "a-b 3.md", "a-b 4.md"])
	}

	@Test func aTitleThatLooksNumberedKeepsItsOwnName() {
		#expect(fileNames(["Note", "Note", "Note 2"]) == ["Note.md", "Note 3.md", "Note 2.md"])
		#expect(fileNames(["Note", "note", "note 2"]) == ["Note.md", "note 3.md", "note 2.md"])
	}

	@Test func theOldestNoteKeepsTheUnnumberedName() {
		let newer = note("Plan", created: 2_000)
		let older = note("Plan", created: 1_000)

		#expect(NoteMarkdown.fileNames(for: [newer, older]) == ["Plan 2.md", "Plan.md"])
	}

	@Test func theSameNotesGetTheSameNamesInAnyOrder() {
		let titles = ["Plan", "plan", "Idea", "", "PLAN 2"]
		let notes = (0..<15).map { note(titles[$0 % titles.count], created: Int64($0 % 3)) }
		let names = NoteMarkdown.fileNames(for: notes)
		let nameByID = Dictionary(uniqueKeysWithValues: zip(notes.map(\.id), names))

		#expect(NoteMarkdown.fileNames(for: notes) == names)
		#expect(Set(names.map { $0.lowercased() }).count == names.count)
		for reordered in [Array(notes.reversed()), Array(notes[7...] + notes[..<7])] {
			#expect(NoteMarkdown.fileNames(for: reordered) == reordered.map { nameByID[$0.id] ?? "" })
		}
	}
}
