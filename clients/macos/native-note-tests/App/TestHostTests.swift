import AppKit
import Testing

@MainActor
struct TestHostTests {
	@Test func theTestHostStaysOutOfTheDockAndInTheBackground() {
		#expect(NSApp.activationPolicy() == .prohibited)
		#expect(!NSApp.isActive)
	}

	private func fileMenu() throws -> NSMenu {
		try #require(NSApp.mainMenu?.items.first { $0.submenu?.item(withTitle: "Export…") != nil }?.submenu)
	}

	@Test func newNoteIsCommandN() throws {
		let item = try #require(try fileMenu().item(withTitle: "New Note"))

		#expect(item.keyEquivalent == "n")
		#expect(item.keyEquivalentModifierMask == .command)
	}

	@Test func lockIsControlCommandL() throws {
		let item = try #require(try fileMenu().item(withTitle: "Lock"))

		#expect(item.keyEquivalent == "l")
		#expect(item.keyEquivalentModifierMask == [.control, .command])
	}

	@Test func libraryCommandsWaitForUnlock() throws {
		let file = try fileMenu()

		file.update()

		for title in ["New Note", "Lock", "Export…", "Import…"] {
			#expect(file.item(withTitle: title)?.isEnabled == false, "\(title)")
		}
	}
}
