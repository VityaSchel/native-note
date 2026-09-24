import AppKit
import Testing

@MainActor
struct TestHostTests {
	@Test func theTestHostStaysOutOfTheDockAndInTheBackground() {
		#expect(NSApp.activationPolicy() == .prohibited)
		#expect(!NSApp.isActive)
	}

	@Test func exportAndImportWaitForUnlock() throws {
		let file = try #require(NSApp.mainMenu?.items.first { $0.submenu?.item(withTitle: "Export…") != nil }?.submenu)

		file.update()

		#expect(file.item(withTitle: "Export…")?.isEnabled == false)
		#expect(file.item(withTitle: "Import…")?.isEnabled == false)
	}
}
