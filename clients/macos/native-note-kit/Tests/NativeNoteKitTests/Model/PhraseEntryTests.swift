import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

func entry(_ words: [String]) -> PhraseEntry {
	var entry = PhraseEntry()
	_ = entry.set(words.joined(separator: " "), at: 0)
	return entry
}

extension PhraseEntry {
	/// One key at a time, as typing sends them.
	mutating func type(_ keys: String, at index: Int) -> Int? {
		var moved: Int?
		for key in keys {
			moved = set(texts[index] + String(key), at: index)
		}
		return moved
	}
}

/// The fields as SwiftUI drives them: a field shows what was typed or pasted into it, and takes a new value only when its bound value changes.
private struct Fields {
	var entry = PhraseEntry()
	var shown = Array(repeating: "", count: PhraseEntry.count)
	var focus = 0

	mutating func edit(_ text: String) {
		let index = focus
		shown[index] = text
		let next = render { $0.set(text, at: index) }
		if let next, next != focus { move(to: next) }
	}

	/// Leaving a field also sends its text to the binding again, as the field editor ends.
	mutating func move(to index: Int) {
		let left = focus
		focus = index
		let ending = shown[left]
		_ = render { $0.set(ending, at: left) }
		render { $0.complete(at: left) }
	}

	private mutating func render<Result>(_ change: (inout PhraseEntry) -> Result) -> Result {
		let before = entry.texts
		let result = change(&entry)
		for index in shown.indices where entry.texts[index] != before[index] {
			shown[index] = entry.texts[index]
		}
		return result
	}
}

struct PhraseEntryTests {
	private let key = SymmetricKey(data: (0 ..< 32).map { UInt8($0 * 7 + 3) })

	private var phrase: [String] {
		get throws { try #require(Mnemonic.words(for: key)) }
	}

	@Test func aPasteFillsEveryFieldFromTheOneItLandsInAndFocusesTheLast() throws {
		var entry = PhraseEntry()

		#expect(entry.set("\n" + (try phrase).joined(separator: " \t").uppercased() + "\n", at: 0) == 23)

		#expect(entry.words == (try phrase))
		#expect(entry.opens && entry.key == key && entry.problem(editing: 23) == nil)
		entry.complete(at: 0)
		#expect(entry.texts == (try phrase))
	}

	@Test func aCopyOfTheNumberedWordsPastesAsTheWords() throws {
		var entry = PhraseEntry()
		let numbered = try phrase.enumerated().map { "\($0.offset + 1). \($0.element)" }

		_ = entry.set(numbered.joined(separator: "\t"), at: 0)

		#expect(entry.words == (try phrase))
	}

	@Test func aNumberedListInAnyOrderPutsEachWordInItsNumberedField() throws {
		var entry = PhraseEntry()
		let numbered = try phrase.enumerated().map { "\($0.offset + 1). \($0.element)" }

		#expect(entry.set(numbered.reversed().joined(separator: "\n"), at: 6) == 23)

		#expect(entry.words == (try phrase))
		entry.complete(at: 6)
		#expect(entry.texts == (try phrase))
	}

	@Test func oneCopiedColumnLandsInItsOwnFieldsWhereverItIsPasted() throws {
		var entry = PhraseEntry()
		let column = try (9 ... 16).map { "\($0 < 10 ? "\u{2007}" : "")\($0). \(try phrase[$0 - 1])" }.joined(separator: "\n")

		#expect(entry.set(column, at: 0) == 16)

		entry.complete(at: 0)
		#expect(Set(entry.words[..<8]) == [""])
		#expect(try Array(entry.words[8 ..< 16]) == Array(phrase[8 ..< 16]))
		#expect(Set(entry.words[16...]) == [""])
	}

	@Test func numbersThatDoNotFollowEveryWordPasteInOrder() throws {
		let words = try phrase
		for (text, count) in [("1. \(words[0]) \(words[1]) 3. \(words[2])", 3), ("1. \(words[0]) 1. \(words[1])", 2), ("30. \(words[0]) 2. \(words[1])", 2)] {
			var entry = PhraseEntry()
			_ = entry.set(text, at: 0)
			entry.complete(at: 0)

			#expect(Array(entry.words.prefix(count + 1)) == Array(words.prefix(count)) + [""], "\(text)")
		}
	}

	@Test func aPasteLandingPartWayFillsTheFieldsAfterItAndDropsWhatDoesNotFit() throws {
		var entry = PhraseEntry()

		#expect(entry.set((try phrase).joined(separator: " "), at: 20) == 23)

		#expect(Set(entry.words[..<20]) == [""])
		#expect(try Array(entry.words[20...]) == Array(phrase.prefix(4)))
	}

	@Test func aPasteOverASelectedWordReplacesItAndMovesOn() {
		var entry = PhraseEntry()
		_ = entry.type("abandon", at: 4)

		#expect(entry.set("5. Able", at: 4) == 5)
		#expect(entry.words[4] == "able")
		entry.complete(at: 4)
		#expect(entry.texts[4] == "able")

		#expect(entry.set("zoo zone", at: 4) == 6)
		#expect(Array(entry.words[4 ... 5]) == ["zoo", "zone"])
		#expect(entry.set("z", at: 4) == nil)
		#expect(entry.texts[4] == "z" && entry.words[4] == "z" && entry.words[5] == "zone")
	}

	@Test func typingOverAPasteInTheLastFieldDropsThePastedWord() {
		var entry = PhraseEntry()

		#expect(entry.set("zoo", at: 23) == 23)
		#expect(entry.set("z", at: 23) == nil)

		#expect(entry.words[23] == "z")
		entry.complete(at: 23)
		#expect(entry.texts[23] == "z")
	}

	@Test func aPasteSplitsAtWhitespaceAndCommasSoAStrayCharacterKeepsAWordWhole() {
		var entry = PhraseEntry()
		_ = entry.type("skil;l", at: 5)
		_ = entry.set("tunnel", at: 6)

		#expect(entry.set("skil;lskill", at: 5) == 6)
		#expect(entry.words[5] == "skil;lskill" && entry.texts[6] == "tunnel")
		#expect(entry.isInvalid(at: 5, editing: 6))

		#expect(entry.set("(abandon),ability;", at: 10) == 12)
		#expect(Array(entry.words[10 ... 11]) == ["abandon", "ability"])
	}

	@Test func aRePasteOverTheSameFirstWordStillFillsEveryField() throws {
		var entry = entry(try phrase)
		entry.complete(at: 0)
		var corrected = try phrase
		corrected.swapAt(5, 6)

		#expect(entry.set(corrected.joined(separator: " "), at: 0) == 23)

		#expect(entry.words == corrected)
	}

	@Test func aPasteOfFourLetterAbbreviationsCompletesEveryWord() throws {
		var entry = PhraseEntry()

		#expect(entry.set(try phrase.map { String($0.prefix(4)) }.joined(separator: " "), at: 0) == 23)

		#expect(entry.words == (try phrase) && entry.opens && entry.key == key)
		#expect(Array(entry.texts[1...]) == Array(try phrase.dropFirst()))
	}

	@Test func aSpaceInAnEmptyFieldOrAPasteWithoutLettersStaysAsTyped() {
		var entry = PhraseEntry()

		#expect(entry.set(" ", at: 1) == nil)
		#expect(entry.set("12", at: 2) == nil)
		#expect(entry.set("--", at: 3) == nil)

		#expect(Array(entry.texts[1 ... 3]) == [" ", "12", "--"] && entry.texts[4].isEmpty)
		entry.complete(at: 1)
		#expect(entry.texts[1].isEmpty)
		var fields = Fields()
		for key in "abandon  ability" {
			fields.edit(fields.shown[fields.focus] + String(key))
		}
		#expect(fields.focus == 1 && fields.shown[1] == " ability" && fields.shown[2].isEmpty)
	}

	@Test func aFieldSendingItsTextAgainAsItEndsKeepsThePastedWord() throws {
		var entry = PhraseEntry()
		let pasted = (try phrase).joined(separator: " ")
		_ = entry.set(pasted, at: 0)

		#expect(entry.set(pasted, at: 0) == nil)
		entry.complete(at: 0)

		#expect(entry.texts[0] == (try phrase)[0])
	}

	@Test func aPastedOrDictatedWordCompletesAndMovesOn() {
		var entry = PhraseEntry()

		#expect(entry.set("Aban", at: 3) == 4)
		#expect(entry.set("Ya", at: 5) == 6)

		#expect(entry.words[3] == "abandon" && entry.words[5] == "yard")
	}

	@Test func aSpaceAfterAWordMovesOnAndLeavingCompletesIt() {
		var entry = PhraseEntry()

		#expect(entry.type("aba", at: 0) == nil)
		#expect(entry.words[0] == "aba" && !entry.isInvalid(at: 0, editing: 0))
		#expect(entry.type(" ", at: 0) == 1)
		entry.complete(at: 0)
		#expect(entry.texts[0] == "abandon")
		#expect(entry.type("ab ", at: 1) == 2)
		entry.complete(at: 1)
		#expect(entry.texts[1] == "ab")
		#expect(entry.isInvalid(at: 1, editing: 2))
	}

	@Test func aSpaceInTheLastFieldStaysThere() {
		var entry = PhraseEntry()

		#expect(entry.type("zoo ", at: 23) == 23)

		#expect(entry.words[23] == "zoo" && entry.texts[23] == "zoo ")
		entry.complete(at: 23)
		#expect(entry.texts[23] == "zoo")
	}

	@Test func aStrayCharacterTypedInAWordStaysInItsFieldAndASpaceLeavesTheNextAlone() {
		var entry = PhraseEntry()
		_ = entry.set("tunnel", at: 6)

		#expect(entry.type("Skil;l", at: 5) == nil)
		#expect(entry.type("aban1", at: 0) == nil)
		#expect(entry.texts[5] == "Skil;l" && entry.texts[0] == "aban1")
		#expect(entry.isInvalid(at: 5, editing: 5))
		#expect(entry.problem(editing: 5) == .unknownWord(0))

		#expect(entry.type(" ", at: 5) == 6)
		entry.complete(at: 5)
		#expect(entry.texts[5] == "Skil;l" && entry.words[6] == "tunnel")
		#expect(entry.isInvalid(at: 5, editing: 6))
	}

	@Test func spacesAroundAWordAreKeptAsTypedAndIgnoredWhenChecking() throws {
		var entry = PhraseEntry()

		#expect(entry.type(" A", at: 0) == nil)
		#expect(entry.texts[0] == " A" && entry.words[0] == "a" && !entry.isInvalid(at: 0, editing: 0))
		#expect(entry.type("ba ", at: 0) == 1)
		entry.complete(at: 0)
		#expect(entry.texts[0] == "abandon")

		var spaced = PhraseEntry()
		for (index, word) in try phrase.enumerated() {
			_ = spaced.type(" \(word) ", at: index)
		}
		#expect(spaced.texts.allSatisfy { $0.hasPrefix(" ") && $0.hasSuffix(" ") })
		#expect(spaced.opens && spaced.key == key)
	}

	@Test func aSpaceTypedInsideAWordDoesNotSplitIt() {
		var entry = PhraseEntry()
		_ = entry.type("abandon", at: 0)

		#expect(entry.set("aba ndon", at: 0) == nil)
		#expect(entry.type(" ", at: 0) == 1)
		_ = entry.set(" ", at: 2)
		#expect(entry.set("a ", at: 2) == nil)
		#expect(entry.texts[2] == "a ")

		#expect(entry.words[0] == "aba ndon" && entry.words[1].isEmpty)
		#expect(entry.isInvalid(at: 0, editing: 1))
	}

	@Test func leavingAFieldCompletesItAndAPrefixLeftBehindIsAnUnknownWord() {
		var entry = PhraseEntry()
		_ = entry.type("zon", at: 4)
		_ = entry.type("zo", at: 5)

		entry.complete(at: 4)
		entry.complete(at: 5)

		#expect(entry.texts[4] == "zone")
		#expect(entry.texts[5] == "zo")
		#expect(entry.isInvalid(at: 5, editing: 5) == false)
		#expect(entry.isInvalid(at: 5, editing: 6))
		#expect(entry.problem(editing: 6) == .unknownWord(5))
		#expect(entry.problem(editing: 5) == nil)
	}

	@Test func aWordOffTheListIsReportedAtOnceWhereverItIs() {
		var entry = PhraseEntry()
		_ = entry.type("abandon", at: 0)
		_ = entry.type("bitcoins", at: 7)

		#expect(entry.isInvalid(at: 7, editing: 7))
		#expect(entry.problem(editing: 7) == .unknownWord(7))
		#expect(!entry.opens)
	}

	@Test func twentyFourListWordsThatFailTheChecksumAreReportedAndDoNotOpen() throws {
		var swapped = try phrase
		swapped.swapAt(0, 1)
		try #require(Mnemonic.key(from: swapped) == nil)

		let entry = entry(swapped)

		#expect(entry.problem(editing: nil) == .checksum)
		#expect(!entry.opens && entry.key == nil)
	}

	@Test func anUnfinishedPhraseHasNoProblemYet() throws {
		let entry = entry(Array(try phrase.prefix(23)))

		#expect(entry.problem(editing: 23) == nil)
		#expect(!entry.opens)
	}

	@Test(arguments: [UInt64(1), 2, 3, 4])
	func everyFieldShowsItsTextThroughRandomTypingPastingAndMoving(seed: UInt64) throws {
		var random = SeededGenerator(seed: seed)
		var fields = Fields()
		let keys = Array("abcdeilnorstuz ;1")
		let samples = try phrase + ["ab", "zo", "skil;l", "5. able", "zoo zone", " aba ", "--", ""]

		for step in 0 ..< 2000 {
			let (index, shown, before) = (fields.focus, fields.shown[fields.focus], fields.entry.texts)
			var typed = true
			switch Int.random(in: 0 ..< 10, using: &random) {
			case 0 ..< 6:
				fields.edit(shown + String(try #require(keys.randomElement(using: &random))))
			case 6:
				fields.edit(String(shown.dropLast()))
			case 7:
				let paste = try #require(samples.randomElement(using: &random))
				fields.edit(Bool.random(using: &random) ? paste : shown + paste)
				typed = false
			case 8:
				fields.edit(String(try #require(keys.randomElement(using: &random))))
			default:
				fields.move(to: Int.random(in: 0 ..< PhraseEntry.count, using: &random))
			}
			try #require(fields.shown == fields.entry.texts, "step \(step)")
			if typed {
				try #require(fields.entry.texts.indices.allSatisfy { $0 == index || fields.entry.texts[$0] == before[$0] }, "step \(step)")
				try #require(fields.entry.words[index] == fields.shown[index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), "step \(step)")
			}
		}
	}

	@Test func typingThroughEveryFieldOpensThePhrase() throws {
		var fields = Fields()

		for word in try phrase {
			for key in word.prefix(4) + " " {
				fields.edit(fields.shown[fields.focus] + String(key))
			}
		}
		fields.move(to: 0)

		#expect(fields.shown == (try phrase))
		#expect(fields.entry.opens && fields.entry.key == key)
	}
}

struct ListWordCheckTests {
	@Test func aListWordOrTheStartOfOneCouldBeAListWordAndATypoCannot() {
		#expect(PhraseEntry.couldBeListWord("abandon"))
		#expect(PhraseEntry.couldBeListWord(" Aban "))
		#expect(PhraseEntry.couldBeListWord(""))
		#expect(!PhraseEntry.couldBeListWord("zzzz"))
	}

	@Test func onlyAWholeListWordIsOneIgnoringCaseAndSpaces() {
		#expect(PhraseEntry.isListWord(" Abandon "))
		#expect(!PhraseEntry.isListWord("aban"))
		#expect(!PhraseEntry.isListWord(""))
		#expect(!PhraseEntry.isListWord("zzzz"))
	}
}
