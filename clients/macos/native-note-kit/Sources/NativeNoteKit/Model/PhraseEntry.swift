import CryptoKit
import Foundation

/// The join's word entry, per clients/DESIGN.md § Recovery flow. Each field's text is exactly what it shows, since
/// SwiftUI leaves a field alone when a write does not change its bound value: the field being edited is tidied only once it is left.
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
	private var settling: [Int: String] = [:]

	public init() {}

	public var words: [String] {
		texts.indices.map(word(at:))
	}

	/// Returns the field to focus after a paste or a space typed after a word: the next one, or `index` in the last field.
	public mutating func set(_ text: String, at index: Int) -> Int? {
		let old = texts[index]
		guard text != old else { return nil }
		texts[index] = text
		settling[index] = nil
		let pasted = Self.words(in: text)
		guard !pasted.isEmpty else { return nil }
		if Self.inserted(text, over: old) > 1 {
			settling[index] = Self.completed(pasted[0])
			for (offset, word) in pasted.enumerated().dropFirst() where index + offset < Self.count {
				texts[index + offset] = Self.completed(word)
				settling[index + offset] = nil
			}
			return min(index + pasted.count, Self.count - 1)
		}
		let spaced = text.count == old.count + 1 && text.hasPrefix(old) && text.last?.isWhitespace == true
		return spaced ? min(index + 1, Self.count - 1) : nil
	}

	public mutating func complete(at index: Int) {
		texts[index] = settling.removeValue(forKey: index) ?? Self.cleaned(texts[index])
	}

	/// A word still being typed in `editing` may be a prefix; anywhere else it must be a whole list word.
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

	/// Whether typed text is a list word or the start of one, so a typo is flagged before the words are checked.
	public static func couldBeListWord(_ text: String) -> Bool {
		let word = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
		settling[index] ?? texts[index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
	}

	private static func cleaned(_ text: String) -> String {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.allSatisfy(\.isLetter) ? completed(trimmed.lowercased()) : trimmed
	}

	/// Words split at whitespace and commas only, so a stray character inside a word keeps it one word.
	private static func words(in text: String) -> [String] {
		text.split { $0.isWhitespace || $0 == "," }
			.map { $0.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted) }
			.filter { !$0.isEmpty }
	}

	/// How many characters an edit put in, measured over a selection too, since a paste over a word need not grow the text.
	private static func inserted(_ text: String, over old: String) -> Int {
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
