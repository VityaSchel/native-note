import Foundation

public final class PhraseLog {
	public private(set) var phrases: [String] = []
	private let read: () throws -> String
	private var latest = ""

	public init(read: @escaping () throws -> String) {
		self.read = read
	}

	public var mark: Int { phrases.count }

	public func poll() {
		guard let phrase = try? read() else { return }
		record(phrase)
	}

	public func record(_ phrase: String) {
		let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, trimmed != latest else { return }
		latest = trimmed
		phrases.append(trimmed)
	}

	public func heard(since mark: Int) -> [String] {
		Array(phrases[min(mark, phrases.count)...])
	}

	public func firstHeard(_ text: String, since mark: Int) -> String? {
		heard(since: mark).first { Self.normalized($0).contains(Self.normalized(text)) }
	}

	public func listen(for seconds: TimeInterval, every interval: TimeInterval = 0.02) {
		let deadline = Date.now.addingTimeInterval(seconds)
		while Date.now < deadline {
			poll()
			Clock.pause(interval)
		}
	}

	public func listen(until text: String, since mark: Int, within seconds: TimeInterval) -> String? {
		let deadline = Date.now.addingTimeInterval(seconds)
		while Date.now < deadline {
			poll()
			if let phrase = firstHeard(text, since: mark) { return phrase }
			Clock.pause(0.02)
		}
		return nil
	}

	public static func normalized(_ text: String) -> String {
		text.lowercased()
			.replacing("\u{2019}", with: "'")
			.replacing("\u{2026}", with: "...")
			.split(whereSeparator: \.isWhitespace)
			.joined(separator: " ")
	}
}
