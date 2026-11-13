import AppKit
import LocalAuthenticationEmbeddedUI
import SwiftUI
import Testing

@testable import NativeNote

extension OffscreenWindow {
	func field(_ name: String, inSheet: Bool = false) throws -> NSSecureTextField {
		try #require(secureField(name, inSheet: inSheet), "\(name)")
	}

	func type(_ text: String, into field: NSTextField) throws {
		try #require((field.window ?? window).makeFirstResponder(field))
		try #require(field.currentEditor()).insertText(text)
		pump()
	}

	@discardableResult
	func type(_ text: String, into name: String, inSheet: Bool = false) throws -> NSSecureTextField {
		let field = try field(name, inSheet: inSheet)
		try type(text, into: field)
		return field
	}

	func button(_ label: String) -> AccessibilityElement? {
		accessibilityElements(.button).first { $0.label == label }
	}

	func press(_ label: String) throws {
		try #require(button(label), "\(label)").press()
		pump()
	}

	func pressOnceShown(_ label: String) async throws {
		await pump { button(label) != nil }
		try press(label)
	}

	func texts() -> [String] {
		accessibilityElements()
			.filter { [.staticText, NSAccessibility.Role(rawValue: "AXHeading")].contains($0.role) }
			.map { $0.value.isEmpty ? $0.label : $0.value }
	}

	func staticTexts() -> [String] {
		accessibilityElements(.staticText).map(\.value)
	}

	var glyphs: [LAAuthenticationView] {
		views(of: LAAuthenticationView.self)
	}

	var tryAgainButton: AccessibilityElement? {
		(accessibilityElements(.button) + sheetAccessibilityElements(.button)).first { $0.label == TouchIDStatus.tryAgainTitle }
	}
}
