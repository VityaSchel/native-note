import ApplicationServices

public struct Element {
	public let role: String
	public let description: String
	public let title: String
	public let value: String
	public let isFocused: Bool
	public let isEnabled: Bool
	let reference: AXUIElement

	public var name: String { [description, title].first { !$0.isEmpty } ?? "" }

	public var characterCount: Int {
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(reference, kAXNumberOfCharactersAttribute as CFString, &value) == .success else { return -1 }
		return (value as? Int) ?? -1
	}

	public func press() {
		AXUIElementPerformAction(reference, kAXPressAction as CFString)
	}

	public static func focused(in pid: pid_t) -> Element? {
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &value) == .success,
			let value, CFGetTypeID(value) == AXUIElementGetTypeID()
		else { return nil }
		return element(value as! AXUIElement)
	}

	public static func menuItem(_ title: String, in pid: pid_t) -> Element? {
		var bar: CFTypeRef?
		guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXMenuBarAttribute as CFString, &bar) == .success, let bar else { return nil }
		var pending = [bar as! AXUIElement]
		while let next = pending.popLast() {
			let read = element(next)
			if read.role == "AXMenuItem", read.title == title { return read }
			pending.append(contentsOf: children(of: next))
		}
		return nil
	}

	public static func all(in pid: pid_t, limit: Int = 4000) -> [Element] {
		var found: [Element] = []
		var pending = [AXUIElementCreateApplication(pid)]
		while let element = pending.popLast(), found.count < limit {
			let read = Self.element(element)
			if read.role != "AXMenuBar" { pending.append(contentsOf: children(of: element).reversed()) }
			found.append(read)
		}
		return found
	}

	private static func element(_ element: AXUIElement) -> Element {
		Element(
			role: string(element, kAXRoleAttribute),
			description: string(element, kAXDescriptionAttribute),
			title: string(element, kAXTitleAttribute),
			value: string(element, kAXValueAttribute),
			isFocused: bool(element, kAXFocusedAttribute),
			isEnabled: bool(element, kAXEnabledAttribute),
			reference: element
		)
	}

	private static func children(of element: AXUIElement) -> [AXUIElement] {
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
		return value as? [AXUIElement] ?? []
	}

	private static func string(_ element: AXUIElement, _ attribute: String) -> String {
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
		return value as? String ?? ""
	}

	private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
		return (value as? Bool) ?? false
	}
}
