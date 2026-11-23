import AppKit
import SwiftUI

@MainActor
struct AccessibilityElement {
	let role: NSAccessibility.Role?
	let label: String
	let value: String
	let placeholder: String
	let frame: NSRect
	let isEnabled: Bool
	private let element: AnyObject

	init(_ element: AnyObject) {
		self.element = element
		role = element.accessibilityRole?()
		label = element.accessibilityLabel?() ?? ""
		let readValue = NSSelectorFromString("accessibilityValue")
		value = (element as? NSObject).flatMap { $0.responds(to: readValue) ? $0.perform(readValue)?.takeUnretainedValue() as? String : nil } ?? ""
		placeholder = element.accessibilityPlaceholderValue?() ?? ""
		frame = element.accessibilityFrame?() ?? .zero
		isEnabled = element.isAccessibilityEnabled?() ?? false
	}

	@discardableResult
	func press() -> Bool {
		element.accessibilityPerformPress?() ?? false
	}
}

extension OffscreenWindow {
	func accessibilityElements() -> [AccessibilityElement] {
		Self.accessibilityElements(under: host)
	}

	func accessibilityElements(_ role: NSAccessibility.Role) -> [AccessibilityElement] {
		accessibilityElements().filter { $0.role == role }
	}

	func sheetAccessibilityElements(_ role: NSAccessibility.Role) -> [AccessibilityElement] {
		guard let content = sheet?.contentView else { return [] }
		return Self.accessibilityElements(under: content).filter { $0.role == role }
	}

	private static func accessibilityElements(under root: NSView) -> [AccessibilityElement] {
		EnhancedAccessibility.reading {
			var found: [AccessibilityElement] = []
			var pending: [AnyObject] = [root]
			while let element = pending.popLast() {
				if element !== root { found.append(AccessibilityElement(element)) }
				pending.append(contentsOf: (element.accessibilityChildren?() ?? []).reversed().map { $0 as AnyObject })
			}
			return found
		}
	}

	func onScreen(_ view: NSView) -> NSRect {
		window.convertToScreen(view.convert(view.bounds, to: nil))
	}
}

@MainActor
struct AttributeElement {
	let role: String
	let subrole: String
	let description: String
	let title: String
	let value: String
	let help: String
	let placeholder: String
	let titleElementText: String
	let inputLabels: [String]
	let actions: [String]
	let isEnabled: Bool
	let frame: NSRect

	var spoken: String { [description, title, value].filter { !$0.isEmpty }.joined(separator: " ") }

	var name: String { [description, title, titleElementText].first { !$0.isEmpty } ?? "" }

	static func walk(from root: AnyObject) -> AccessibilityWalk {
		var walk = AccessibilityWalk()
		var visited: [ObjectIdentifier: AnyObject] = [:]
		var pending: [AnyObject] = [root]
		while let element = pending.popLast(), walk.elements.count < 5000 {
			let reader = Reader(element)
			let read = AttributeElement(reader)
			guard visited.updateValue(element, forKey: ObjectIdentifier(element)) == nil else {
				walk.loops.append(read)
				continue
			}
			walk.elements.append(read)
			pending.append(contentsOf: reader.children.reversed())
		}
		return walk
	}

	static func children(of element: AnyObject) -> [AnyObject] {
		Reader(element).children
	}

	private init(_ reader: Reader) {
		let element = reader.element
		role = element.accessibilityRole?()?.rawValue ?? reader.legacy(.role) as? String ?? ""
		subrole = element.accessibilitySubrole?()?.rawValue ?? reader.legacy(.subrole) as? String ?? ""
		description = Self.nonEmpty(element.accessibilityLabel?()) ?? reader.legacy(.description) as? String ?? ""
		title = Self.nonEmpty(element.accessibilityTitle?()) ?? reader.legacy(.title) as? String ?? ""
		value = Self.nonEmpty(Self.text(reader.call("accessibilityValue"))) ?? Self.text(reader.legacy(.value)) ?? ""
		help = Self.nonEmpty(element.accessibilityHelp?()) ?? reader.legacy(.help) as? String ?? ""
		placeholder = Self.nonEmpty(element.accessibilityPlaceholderValue?()) ?? reader.legacy(.placeholderValue) as? String ?? ""
		let titleElement = (element.accessibilityTitleUIElement?() ?? reader.legacy(.titleUIElement)).map { $0 as AnyObject }
		titleElementText = titleElement.flatMap { Self.nonEmpty(Self.text(Reader($0).call("accessibilityValue"))) ?? Self.nonEmpty($0.accessibilityTitle?()) } ?? ""
		inputLabels = reader.call("accessibilityUserInputLabels") as? [String] ?? reader.legacy(NSAccessibility.Attribute(rawValue: "AXUserInputLabels")) as? [String] ?? []
		actions = reader.actions
		isEnabled = element.isAccessibilityEnabled?() ?? (reader.legacy(.enabled) as? Bool ?? false)
		frame = element.accessibilityFrame?() ?? .zero
	}

	private static func nonEmpty(_ text: String?) -> String? {
		text.flatMap { $0.isEmpty ? nil : $0 }
	}

	private static func text(_ value: Any?) -> String? {
		switch value {
		case let text as String: text
		case let text as NSAttributedString: text.string
		case let number as NSNumber: number.stringValue
		default: nil
		}
	}

	@MainActor private struct Reader {
		let element: AnyObject
		private let names: Set<String>

		init(_ element: AnyObject) {
			self.element = element
			names = Set(Self.perform("accessibilityAttributeNames", on: element) as? [String] ?? [])
		}

		var children: [AnyObject] {
			(element.accessibilityChildren?() ?? legacy(.children) as? [Any] ?? []).map { $0 as AnyObject }
		}

		var actions: [String] {
			let named = call("accessibilityActionNames") as? [String] ?? []
			let performed = [("accessibilityPerformPress", "AXPress"), ("accessibilityPerformShowMenu", "AXShowMenu")].filter { allows($0.0) }.map(\.1)
			return named + performed.filter { !named.contains($0) }
		}

		private func allows(_ name: String) -> Bool {
			let selector = NSSelectorFromString(name)
			guard let object = element as? NSObject, object.responds(to: selector) else { return false }
			return element.isAccessibilitySelectorAllowed?(selector) ?? true
		}

		func call(_ selector: String) -> Any? {
			Self.perform(selector, on: element)
		}

		func legacy(_ attribute: NSAccessibility.Attribute) -> Any? {
			guard names.contains(attribute.rawValue) else { return nil }
			let read = NSSelectorFromString("accessibilityAttributeValue:")
			guard let object = element as? NSObject, object.responds(to: read) else { return nil }
			return object.perform(read, with: attribute.rawValue)?.takeUnretainedValue()
		}

		private static func perform(_ name: String, on element: AnyObject) -> Any? {
			let selector = NSSelectorFromString(name)
			guard let object = element as? NSObject, object.responds(to: selector) else { return nil }
			return object.perform(selector)?.takeUnretainedValue()
		}
	}
}

@MainActor
struct AccessibilityWalk {
	var elements: [AttributeElement] = []
	var loops: [AttributeElement] = []
}

extension OffscreenWindow {
	func attributeTree() -> [AttributeElement] {
		attributeWalk(of: window).elements
	}

	func attributeWalk(of target: NSWindow) -> AccessibilityWalk {
		EnhancedAccessibility.reading {
			_ = AttributeElement.walk(from: target)
			pump(for: 0.5)
			return AttributeElement.walk(from: target)
		}
	}
}

@MainActor
enum EnhancedAccessibility {
	private(set) static var readers = 0

	static var isOn: Bool {
		let read = NSSelectorFromString("accessibilityAttributeValue:")
		return (NSApp.perform(read, with: "AXEnhancedUserInterface")?.takeUnretainedValue() as? NSNumber)?.boolValue ?? false
	}

	static func reading<Read>(_ read: () -> Read) -> Read {
		if readers == 0 { set(true) }
		readers += 1
		defer {
			readers -= 1
			if readers == 0 { set(false) }
		}
		return read()
	}

	static func reading<Read>(_ read: () async throws -> Read) async rethrows -> Read {
		if readers == 0 { set(true) }
		readers += 1
		defer {
			readers -= 1
			if readers == 0 { set(false) }
		}
		return try await read()
	}

	private static func set(_ isOn: Bool) {
		NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: isOn, with: "AXEnhancedUserInterface")
	}
}
