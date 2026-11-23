import AppKit
import Testing
import Vision

enum AuditRule: String, CaseIterable, Sendable {
	case unnamedControl, placeholderOnlyName, roleWordInName, rawIdentifierName, reachableDecorativeImage, unhiddenSpinner
	case notPressable, missingText, unexpectedText, duplicateButtonName, loop, emptyTree
}

struct AuditFinding: CustomStringConvertible {
	let rule: AuditRule
	let role: String
	let name: String
	let detail: String

	var description: String {
		"\(rule): \(role) \"\(name)\"\(detail.isEmpty ? "" : " \(detail)")"
	}
}

struct DrawnLine {
	let text: String
	let frame: NSRect
}

struct AuditExpectations {
	var mustHear: [String] = []
	var mustNotHear: [String] = []
	var informativeImages: Set<String> = []
}

@MainActor
enum AccessibilityAudit {
	static let pressable: Set<String> = ["AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle"]
	static let editable: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSlider", "AXIncrementor"]
	static let spinners: Set<String> = ["AXProgressIndicator", "AXBusyIndicator"]
	static let roleWords = ["button", "checkbox", "check box", "radio button", "switch", "text field", "image", "icon", "selected", "checked", "unchecked", "dimmed", "disabled"]
	// AppKit's titlebar buttons, which VoiceOver names by their subrole.
	static let appKitWindowButtons: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]
	// AppKit's scroll bar parts, which VoiceOver speaks as part of the scroll bar.
	static let appKitScrollBarParts: Set<String> = ["AXIncrementArrow", "AXDecrementArrow", "AXIncrementPage", "AXDecrementPage"]
	// The .searchable toolbar item is AppKit's: its field is named by its "Search" placeholder, and its collapsed button repeats "Search", as in Notes and Mail.
	static let appKitSearchField = "AXSearchField"

	static func findings(in walks: [AccessibilityWalk], showing lines: [DrawnLine] = [], expecting expectations: AuditExpectations) -> [AuditFinding] {
		let elements = walks.flatMap { audited($0.elements) }
		var findings = walks.flatMap { $0.loops.map { AuditFinding(rule: .loop, role: $0.role, name: $0.name, detail: "is reached twice") } }
		findings += elements.flatMap { problems(of: $0, informativeImages: expectations.informativeImages) }
		for walk in walks {
			let buttons = audited(walk.elements).filter { $0.role == "AXButton" && !$0.name.isEmpty && $0.subrole != appKitSearchField }
			for (name, named) in Dictionary(grouping: buttons, by: \.name) where named.count > 1 {
				let placed = named.map { "\($0.subrole) \(NSStringFromRect($0.frame))" }.joined(separator: ", ")
				findings.append(AuditFinding(rule: .duplicateButtonName, role: "AXButton", name: name, detail: "names \(named.count) buttons: \(placed)"))
			}
		}
		let placed = elements.map { (frame: $0.frame, heard: normalized(([$0.spoken, $0.placeholder, $0.titleElementText, $0.help] + $0.inputLabels).joined(separator: " "))) }
		let heard = placed.map(\.heard)
		if !elements.contains(where: { !$0.spoken.isEmpty }) {
			findings.append(AuditFinding(rule: .emptyTree, role: "", name: "", detail: "has nothing to speak"))
		}
		for text in expectations.mustHear where !heard.contains(where: { $0.contains(normalized(text)) }) {
			findings.append(AuditFinding(rule: .missingText, role: "", name: text, detail: "is never spoken"))
		}
		for text in expectations.mustNotHear where heard.contains(where: { $0.contains(normalized(text)) }) {
			findings.append(AuditFinding(rule: .unexpectedText, role: "", name: text, detail: "is spoken"))
		}
		for line in lines {
			let nearby = placed.filter { $0.frame.intersects(line.frame.insetBy(dx: -4, dy: -4)) }.map(\.heard)
			guard !isSpoken(line.text, from: Set(nearby.flatMap(words))), !nearby.contains(where: { letters($0).contains(letters(line.text)) }) else { continue }
			findings.append(AuditFinding(rule: .missingText, role: "", name: line.text, detail: "is drawn but not spoken where it is drawn"))
		}
		return findings
	}

	private static func audited(_ elements: [AttributeElement]) -> [AttributeElement] {
		elements.filter { $0.role != "AXWindow" && !appKitWindowButtons.contains($0.subrole) && !appKitScrollBarParts.contains($0.subrole) }
	}

	private static func problems(of element: AttributeElement, informativeImages: Set<String>) -> [AuditFinding] {
		let role = element.role
		let name = element.name
		var found: [AuditRule] = []
		var detail = ""
		let control = pressable.contains(role) || editable.contains(role)
		if control, name.isEmpty, element.subrole != appKitSearchField {
			found.append(element.placeholder.isEmpty ? .unnamedControl : .placeholderOnlyName)
			detail = element.placeholder.isEmpty ? "" : "is named only by its placeholder \"\(element.placeholder)\""
		}
		if control || role == "AXImage" {
			if containsRoleWord(name) { found.append(.roleWordInName) }
			if isRawIdentifier(name) { found.append(.rawIdentifierName) }
		}
		if role == "AXImage", !informativeImages.contains(name) {
			found.append(.reachableDecorativeImage)
		}
		if spinners.contains(role), name.isEmpty {
			found.append(.unhiddenSpinner)
		}
		let opensMenu = ["AXPopUpButton", "AXMenuButton"].contains(role) && element.actions.contains("AXShowMenu")
		if pressable.contains(role), element.isEnabled, !element.actions.contains("AXPress"), !opensMenu {
			found.append(.notPressable)
			detail = "offers \(element.actions)"
		}
		return found.map { AuditFinding(rule: $0, role: element.subrole.isEmpty ? role : "\(role)/\(element.subrole)", name: name, detail: detail) }
	}

	static func containsRoleWord(_ name: String) -> Bool {
		let spaced = " \(words(normalized(name)).joined(separator: " ")) "
		return roleWords.contains { spaced.contains(" \($0) ") }
	}

	static func isRawIdentifier(_ name: String) -> Bool {
		guard !name.isEmpty else { return false }
		return name.wholeMatch(of: /[a-z0-9]+(\.[a-z0-9]+)+/) != nil || name.allSatisfy { !$0.isLetter }
	}

	private static let latinLookalikes: [Character: Character] = [
		"а": "a", "в": "b", "е": "e", "к": "k", "м": "m", "н": "h", "о": "o", "р": "p", "с": "c", "т": "t", "у": "y", "х": "x", "і": "i", "ј": "j", "ѕ": "s",
	]

	static func normalized(_ text: String) -> String {
		String(text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US")).lowercased().map { latinLookalikes[$0] ?? $0 })
			.replacing("\u{2019}", with: "'")
			.split(whereSeparator: \.isWhitespace)
			.joined(separator: " ")
	}

	static func words(_ text: String) -> [String] {
		normalized(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
	}

	static func letters(_ text: String) -> String {
		String(normalized(text).filter { $0.isLetter || $0.isNumber })
	}

	static func isSpoken(_ line: String, from vocabulary: Set<String>) -> Bool {
		let drawn = words(line).filter { $0.count >= 3 && Set($0).count > 1 && !isMisread($0) }
		guard drawn.reduce(0, { $0 + $1.count }) >= 4 else { return true }
		let heard = drawn.filter { word in vocabulary.contains(word) || word.count >= 5 && vocabulary.contains { abs($0.count - word.count) <= 1 && isOneEditAway($0, word) } }
		return heard.count * 2 >= drawn.count
	}

	private static func isMisread(_ word: String) -> Bool {
		word.contains(where: \.isLetter) && word.contains(where: \.isNumber)
	}

	private static func isOneEditAway(_ first: String, _ second: String) -> Bool {
		let (a, b) = (Array(first), Array(second))
		var (i, j, edits) = (0, 0, 0)
		while i < a.count, j < b.count {
			if a[i] == b[j] {
				i += 1
				j += 1
				continue
			}
			edits += 1
			if edits > 1 { return false }
			if a.count > b.count {
				i += 1
			} else if b.count > a.count {
				j += 1
			} else {
				i += 1
				j += 1
			}
		}
		return edits + (a.count - i) + (b.count - j) <= 1
	}
}

@MainActor
struct DrawnText {
	private let view: NSView
	private let recognizing: Task<[(text: String, box: CGRect)], Error>

	init(_ view: NSView) throws {
		let background = Appearance.light.resolve(.windowBackgroundColor)
		let snapshot = try #require(Snapshot(of: view, over: background))
		let image = try #require(snapshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
		self.view = view
		recognizing = Task.detached { try await Self.recognize(image) }
	}

	func lines() async throws -> [DrawnLine] {
		let found = try await recognizing.value
		let size = view.bounds.size
		guard let window = view.window else { return [] }
		return found.map { text, box in
			let rect = NSRect(x: box.minX * size.width, y: (view.isFlipped ? 1 - box.maxY : box.minY) * size.height, width: box.width * size.width, height: box.height * size.height)
			return DrawnLine(text: text, frame: window.convertToScreen(view.convert(rect, to: nil)))
		}
	}

	private nonisolated static func recognize(_ image: CGImage) async throws -> [(text: String, box: CGRect)] {
		let request = VNRecognizeTextRequest()
		request.recognitionLevel = .fast
		request.usesLanguageCorrection = false
		request.recognitionLanguages = ["en-US"]
		try VNImageRequestHandler(cgImage: image).perform([request])
		return (request.results ?? []).compactMap { observation in
			observation.topCandidates(1).first.map { ($0.string, observation.boundingBox) }
		}
	}
}

extension OffscreenWindow {
	func audit(expecting expectations: AuditExpectations) async throws -> [AuditFinding] {
		let light = NSAppearance(named: .aqua)
		window.appearance = light
		sheet?.appearance = light
		pump(for: 0.05)
		let targets: [NSWindow] = [window] + (sheet.map { [$0] } ?? [])
		return try await EnhancedAccessibility.reading {
			for target in targets { _ = AttributeElement.walk(from: target) }
			pump(for: 0.5)
			let drawn = try targets.compactMap(\.contentView).map(DrawnText.init)
			let walks = targets.map { AttributeElement.walk(from: $0) }
			var lines: [DrawnLine] = []
			for text in drawn { lines += try await text.lines() }
			return AccessibilityAudit.findings(in: walks, showing: lines, expecting: expectations)
		}
	}
}
