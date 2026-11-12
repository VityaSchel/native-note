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
		let setValue = NSSelectorFromString("accessibilitySetValue:forAttribute:")
		NSApp.perform(setValue, with: true, with: "AXEnhancedUserInterface")
		defer { NSApp.perform(setValue, with: false, with: "AXEnhancedUserInterface") }
		var found: [AccessibilityElement] = []
		var pending: [AnyObject] = [root]
		while let element = pending.popLast() {
			if element !== root { found.append(AccessibilityElement(element)) }
			pending.append(contentsOf: (element.accessibilityChildren?() ?? []).reversed().map { $0 as AnyObject })
		}
		return found
	}

	func onScreen(_ view: NSView) -> NSRect {
		window.convertToScreen(view.convert(view.bounds, to: nil))
	}
}

@MainActor
struct AttributeElement {
	let role: String
	let description: String
	let title: String
	let value: String

	var spoken: String { [description, title, value].filter { !$0.isEmpty }.joined(separator: " ") }

	static func tree(of window: NSWindow) -> [AttributeElement] {
		var found: [AttributeElement] = []
		var pending: [AnyObject] = [window]
		while let element = pending.popLast(), found.count < 5000 {
			found.append(AttributeElement(
				role: element.accessibilityRole?()?.rawValue ?? read(.role, of: element) as? String ?? "",
				description: nonEmpty(element.accessibilityLabel?()) ?? read(.description, of: element) as? String ?? "",
				title: nonEmpty(element.accessibilityTitle?()) ?? read(.title, of: element) as? String ?? "",
				value: nonEmpty(callValue(of: element)) ?? read(.value, of: element) as? String ?? ""
			))
			let children = element.accessibilityChildren?() ?? read(.children, of: element) as? [Any] ?? []
			pending.append(contentsOf: children.reversed().map { $0 as AnyObject })
		}
		return found
	}

	private static func nonEmpty(_ text: String?) -> String? {
		text.flatMap { $0.isEmpty ? nil : $0 }
	}

	private static func callValue(of element: AnyObject) -> String? {
		let selector = NSSelectorFromString("accessibilityValue")
		guard let object = element as? NSObject, object.responds(to: selector) else { return nil }
		return object.perform(selector)?.takeUnretainedValue() as? String
	}

	private static func read(_ attribute: NSAccessibility.Attribute, of element: AnyObject) -> Any? {
		let selector = NSSelectorFromString("accessibilityAttributeValue:")
		guard let object = element as? NSObject, object.responds(to: selector) else { return nil }
		return object.perform(selector, with: attribute.rawValue)?.takeUnretainedValue()
	}
}

extension OffscreenWindow {
	func attributeTree() -> [AttributeElement] {
		let setValue = NSSelectorFromString("accessibilitySetValue:forAttribute:")
		NSApp.perform(setValue, with: true, with: "AXEnhancedUserInterface")
		defer { NSApp.perform(setValue, with: false, with: "AXEnhancedUserInterface") }
		_ = AttributeElement.tree(of: window)
		pump(for: 0.5)
		return AttributeElement.tree(of: window)
	}
}
