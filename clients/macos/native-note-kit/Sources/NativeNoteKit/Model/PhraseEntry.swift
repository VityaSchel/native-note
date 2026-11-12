import CryptoKit
import Foundation

public nonisolated struct PhraseEntry: Equatable, Sendable {
	public enum Problem: Equatable {
		case unknownWord(Int)
		case checksum
	}

	enum Word: Equatable {
		case empty
		case typing
		case known
		case unknown
	}

	public static let count = Mnemonic.wordCount
	public private(set) var texts = Array(repeating: "", count: count)
	private var deferredUntilLeft: [Int: String] = [:]

	public init() {}

	public var words: [String] {
		texts.indices.map(word(at:))
	}

	public mutating func set(_ text: String, at index: Int) -> Int? {
		let old = texts[index]
		guard text != old else { return nil }
		texts[index] = text
		deferredUntilLeft[index] = nil
		let pasted = Self.words(in: text)
		guard !pasted.isEmpty else { return nil }
		let isPaste = Self.insertedCharacterCount(text, over: old) > 1
		if isPaste, let numbered = Self.numberedWords(in: text) {
			deferredUntilLeft[index] = numbered[index].map(Self.completed) ?? old
			for (number, word) in numbered where number != index {
				texts[number] = Self.completed(word)
				deferredUntilLeft[number] = nil
			}
			return min((numbered.keys.max() ?? index) + 1, Self.count - 1)
		}
		if isPaste {
			deferredUntilLeft[index] = Self.completed(pasted[0])
			for (offset, word) in pasted.enumerated().dropFirst() where index + offset < Self.count {
				texts[index + offset] = Self.completed(word)
				deferredUntilLeft[index + offset] = nil
			}
			return min(index + pasted.count, Self.count - 1)
		}
		let spaced = text.count == old.count + 1 && text.hasPrefix(old) && text.last?.isWhitespace == true
		return spaced ? min(index + 1, Self.count - 1) : nil
	}

	public mutating func complete(at index: Int) {
		texts[index] = deferredUntilLeft.removeValue(forKey: index) ?? Self.cleaned(texts[index])
	}

	public func isInvalid(at index: Int, editing: Int?) -> Bool {
		switch state(at: index) {
		case .empty, .known: false
		case .typing: index != editing
		case .unknown: true
		}
	}

	public func problem(editing: Int?) -> Problem? {
		if let index = texts.indices.first(where: { isInvalid(at: $0, editing: editing) }) { return .unknownWord(index) }
		return texts.indices.allSatisfy({ state(at: $0) == .known }) && key == nil ? .checksum : nil
	}

	public var opens: Bool {
		key != nil
	}

	var key: SymmetricKey? {
		Mnemonic.key(from: words)
	}

	public static func isListWord(_ text: String) -> Bool {
		let word = normalized(text)
		return Mnemonic.wordlist?.contains(word) == true
	}

	public static func couldBeListWord(_ text: String) -> Bool {
		let word = normalized(text)
		guard !word.isEmpty, let wordlist = Mnemonic.wordlist else { return true }
		return wordlist.contains { $0.hasPrefix(word) }
	}

	func state(at index: Int) -> Word {
		let word = word(at: index)
		guard !word.isEmpty else { return .empty }
		guard let wordlist = Mnemonic.wordlist else { return .unknown }
		if wordlist.contains(word) { return .known }
		return wordlist.contains { $0.hasPrefix(word) } ? .typing : .unknown
	}

	private func word(at index: Int) -> String {
		deferredUntilLeft[index] ?? Self.normalized(texts[index])
	}

	private static func normalized(_ text: String) -> String {
		text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
	}

	private static func isWordSeparator(_ character: Character) -> Bool {
		character.isWhitespace || character == ","
	}

	private static func cleaned(_ text: String) -> String {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.allSatisfy(\.isLetter) ? completed(trimmed.lowercased()) : trimmed
	}

	private static func words(in text: String) -> [String] {
		text.split(whereSeparator: isWordSeparator)
			.map { $0.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted) }
			.filter { !$0.isEmpty }
	}

	private static func numberedWords(in text: String) -> [Int: String]? {
		var number: Int?
		var placed: [Int: String] = [:]
		for token in text.split(whereSeparator: isWordSeparator) {
			let digits = token.prefix(while: \.isNumber)
			let rest = token.dropFirst(digits.count).drop { $0 == "." || $0 == ")" }
			if !digits.isEmpty {
				guard number == nil, let value = Int(digits), (1 ... count).contains(value) else { return nil }
				number = value - 1
			}
			let word = rest.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
			guard !word.isEmpty else { continue }
			guard let field = number, placed[field] == nil else { return nil }
			placed[field] = word
			number = nil
		}
		return placed.count > 1 && number == nil ? placed : nil
	}

	private static func insertedCharacterCount(_ text: String, over old: String) -> Int {
		let (new, was) = (Array(text), Array(old))
		let prefix = zip(new, was).prefix { $0 == $1 }.count
		let suffix = zip(new.dropFirst(prefix).reversed(), was.dropFirst(prefix).reversed()).prefix { $0 == $1 }.count
		return new.count - prefix - suffix
	}

	private static func completed(_ prefix: String) -> String {
		let matches = Mnemonic.wordlist?.filter { $0.hasPrefix(prefix) } ?? []
		return matches.count == 1 && !prefix.isEmpty ? matches[0] : prefix
	}
}
