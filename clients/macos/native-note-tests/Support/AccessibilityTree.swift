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
		value = (element as? NSObject)?.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue() as? String ?? ""
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
		let setValue = NSSelectorFromString("accessibilitySetValue:forAttribute:")
		NSApp.perform(setValue, with: true, with: "AXEnhancedUserInterface")
		defer { NSApp.perform(setValue, with: false, with: "AXEnhancedUserInterface") }
		var found: [AccessibilityElement] = []
		var pending: [AnyObject] = [host]
		while let element = pending.popLast() {
			if element !== host { found.append(AccessibilityElement(element)) }
			pending.append(contentsOf: (element.accessibilityChildren?() ?? []).reversed().map { $0 as AnyObject })
		}
		return found
	}

	func accessibilityElements(_ role: NSAccessibility.Role) -> [AccessibilityElement] {
		accessibilityElements().filter { $0.role == role }
	}

	func onScreen(_ view: NSView) -> NSRect {
		window.convertToScreen(view.convert(view.bounds, to: nil))
	}
}
