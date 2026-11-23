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

	@discardableResult
	func submit(_ text: String, in name: String) throws -> NSSecureTextField {
		let field = try type(text, into: name)
		try #require(field.currentEditor()).insertNewline(nil)
		pump()
		return field
	}

	func editableTextFields(inSheet: Bool = false) -> [NSTextField] {
		(inSheet ? sheetViews(of: NSTextField.self) : views(of: NSTextField.self)).filter { $0.isEditable && !($0 is NSSecureTextField) }
	}

	func secureFieldsTopDown() -> [NSSecureTextField] {
		views(of: NSSecureTextField.self).sorted { onScreen($0).maxY > onScreen($1).maxY }
	}

	func pressEscape(in target: NSWindow? = nil) throws -> Bool {
		try pressKey("\u{1b}", keyCode: 53, in: target)
	}

	func pressReturn(in target: NSWindow? = nil) throws -> Bool {
		try pressKey("\r", keyCode: 36, in: target)
	}

	private func pressKey(_ characters: String, keyCode: UInt16, in target: NSWindow?) throws -> Bool {
		let event = try #require(
			NSEvent.keyEvent(
				with: .keyDown,
				location: .zero,
				modifierFlags: [],
				timestamp: 0,
				windowNumber: (target ?? window).windowNumber,
				context: nil,
				characters: characters,
				charactersIgnoringModifiers: characters,
				isARepeat: false,
				keyCode: keyCode
			)
		)
		let handled = target.map { $0.performKeyEquivalent(with: event) } ?? host.performKeyEquivalent(with: event)
		pump()
		return handled
	}

	func pressLink(_ label: String) throws {
		try #require(accessibilityElements(.link).first { $0.label == label }, "\(label)").press()
		pump()
	}

	func press(_ label: String) throws {
		try #require(button(label), "\(label)").press()
		pump()
	}

	func pressOnceShown(_ label: String) async throws {
		await pump { button(label) != nil }
		try press(label)
	}

	var exposesASpinner: Bool {
		accessibilityElements().contains { AccessibilityAudit.spinners.contains($0.role?.rawValue ?? "") }
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
