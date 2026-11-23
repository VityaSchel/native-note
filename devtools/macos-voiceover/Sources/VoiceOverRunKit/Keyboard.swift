import ApplicationServices

public enum Keyboard {
	public enum Key: CGKeyCode {
		case returnKey = 36
		case tab = 48
		case escape = 53
		case delete = 51
		case n = 45
		case l = 37
		case r = 15
		case z = 6
		case w = 13
		case q = 12
		case comma = 43
		case a = 0
		case v = 9
	}

	public static var isTrusted: Bool {
		AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
	}

	public static func press(_ key: Key, _ flags: CGEventFlags = []) {
		post(key.rawValue, flags: flags, down: true)
		post(key.rawValue, flags: flags, down: false)
		Clock.pause(0.05)
	}

	public static func type(_ text: String) {
		for character in text {
			let units = Array(String(character).utf16)
			for down in [true, false] {
				let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
				event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
				event?.post(tap: .cghidEventTap)
			}
			Clock.pause(0.02)
		}
		Clock.pause(0.05)
	}

	private static let source = CGEventSource(stateID: .hidSystemState)

	private static func post(_ code: CGKeyCode, flags: CGEventFlags, down: Bool) {
		let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
		event?.flags = flags
		event?.post(tap: .cghidEventTap)
	}
}
