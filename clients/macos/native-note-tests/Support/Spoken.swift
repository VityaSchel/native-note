import Foundation

@MainActor
final class Spoken {
	var heard: [String] = []
	private(set) var lines: [AttributedString] = []

	func hear(_ line: AttributedString) {
		lines.append(line)
		heard.append(String(line.characters))
	}
}
