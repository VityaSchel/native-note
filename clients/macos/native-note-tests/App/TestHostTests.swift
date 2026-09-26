import AppKit
import Testing

@testable import NativeNote
@testable import NativeNoteKit

@MainActor
struct TestHostTests {
	@Test func theTestHostNeverOpensTheRealLibrary() throws {
		let model = AppDelegate().model

		try #require(model.libraryDirectory == AppDelegate.testHostLibrary)
		try #require(model.libraryDirectory.standardizedFileURL != AppLock.directory.standardizedFileURL)
		model.start()
		#expect(model.phase == .needsSetup)
	}

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

	@Test func settingsIsCommandComma() throws {
		let app = try #require(NSApp.mainMenu?.items.first?.submenu)
		let settings = try #require(app.items.first { $0.keyEquivalent == "," })

		#expect(settings.title == "Settings…")
		#expect(settings.keyEquivalentModifierMask == .command)
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
