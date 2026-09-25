import Foundation

struct SeededGenerator: RandomNumberGenerator {
	private var state: UInt64

	init(seed: UInt64) {
		state = seed
	}

	mutating func next() -> UInt64 {
		state &+= 0x9E37_79B9_7F4A_7C15
		var mixed = state
		mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
		mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
		return mixed ^ (mixed >> 31)
	}
}

enum RealisticCorpus {
	private static let titles = [
		"Shopping", "Trip to Lisbon", "Meeting notes 2026-09-24", "Ideas", "買い物リスト", "ملاحظات الاجتماع",
		"Rezept: Käsespätzle", "TODO: fix / refactor", "CON", ".hidden", "a:b\\c", "🎉 Party 👨‍👩‍👧‍👦", "Cafe\u{0301}", "Café",
		"Books to read", "Passwords? No.", "Встреча с командой", "שיעורי בית", "Plan", "Plan", "PLAN",
		String(repeating: "Very long title ", count: 24),
	]

	private static let words = [
		"the", "note", "quartz", "bread", "ferry", "meeting", "draft", "sync", "Lisbon", "kettle", "idea", "later",
		"日本語", "テキスト", "مرحبا", "العالم", "Grüße", "naïve", "façade", "😀", "👍🏽", "🇵🇹", "résumé", "Ω", "∑",
	]

	static func bodies(count: Int, seed: UInt64 = 0x5EED) -> [String] {
		var generator = SeededGenerator(seed: seed)
		return (0 ..< count).map { index in body(index, using: &generator) }
	}

	private static func body(_ index: Int, using generator: inout SeededGenerator) -> String {
		let title = titles[index % titles.count]
		switch index % 12 {
		case 0: return ""
		case 1: return title
		case 2: return "\(title)\n" + (1 ... Int.random(in: 2 ... 12, using: &generator)).map { "- item \($0) \(sentence(3, using: &generator))" }.joined(separator: "\n")
		case 3: return "\(title)\r\n" + (0 ..< 5).map { _ in sentence(12, using: &generator) }.joined(separator: "\r\n")
		case 4: return "---\nid: not-front-matter\n---\n\(title)\n---\n\(sentence(20, using: &generator))\n"
		case 5: return "\(title)\n```swift\nlet value = \"\\(\(index))\"\n\tprint(value)\n```\n| a | b |\n|---|---|\n| 1 | 2 |"
		case 6: return "\(title)\n" + (0 ..< Int.random(in: 400 ... 2_500, using: &generator)).map { _ in sentence(14, using: &generator) }.joined(separator: "\n")
		case 7: return "  \(title)  \n\n\n\(sentence(8, using: &generator))\n\n  \t\n"
		case 8: return "\(title)\nembedded\u{0}nul and \u{7} bell\n\(sentence(6, using: &generator))"
		case 9: return "\(title)\n" + String(repeating: "e\u{0301}", count: 200) + "\n" + String(repeating: "👨‍👩‍👧‍👦", count: 50)
		default: return "\(title)\n" + (0 ..< Int.random(in: 1 ... 40, using: &generator)).map { _ in sentence(Int.random(in: 4 ... 20, using: &generator), using: &generator) }.joined(separator: "\n\n")
		}
	}

	private static func sentence(_ length: Int, using generator: inout SeededGenerator) -> String {
		(0 ..< length).map { _ in words.randomElement(using: &generator)! }.joined(separator: " ")
	}
}
