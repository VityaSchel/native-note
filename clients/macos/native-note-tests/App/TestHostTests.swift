import AppKit
import Testing

@testable import NativeNote
@testable import NativeNoteKit

@MainActor
struct TestHostTests {
	@Test func theTestHostNeverOpensTheRealLibrary() throws {
		let model = AppDelegate().model

		try #require(model.directory == AppDelegate.testHostLibrary)
		try #require(model.directory.standardizedFileURL != AppLock.directory.standardizedFileURL)
		model.start()
		#expect(model.phase == .needsSetup)
	}

	@Test func onlyTheAppOutsideTheTestHostUsesTheSystemFindPasteboard() {
		#expect(FindPasteboard.name(hostingTests: false) == .find)
		#expect(FindPasteboard.name(hostingTests: true) != .find)
		#expect(FindPasteboard.shared.pasteboard.name == FindPasteboard.name(hostingTests: true))
	}

	@Test func theTestHostStaysOutOfTheDockAndInTheBackground() {
		#expect(NSApp.activationPolicy() == .prohibited)
		#expect(!NSApp.isActive)
	}

	private func fileMenu() throws -> NSMenu {
		try #require(NSApp.mainMenu?.items.first { $0.submenu?.item(withTitle: "Export…") != nil }?.submenu)
	}

	private func menu(containing title: String) -> NSMenuItem? {
		func search(_ menu: NSMenu) -> NSMenuItem? {
			for item in menu.items {
				if item.title == title { return item }
				if let found = item.submenu.flatMap(search) { return found }
			}
			return nil
		}
		return NSApp.mainMenu.flatMap(search)
	}

	@Test func theStandardFindSpellingAndSidebarCommandsAreThere() throws {
		let find = try #require(menu(containing: "Find…"))
		#expect(find.keyEquivalent == "f" && find.keyEquivalentModifierMask == .command)
		#expect(menu(containing: "Check Spelling While Typing") != nil)
		let sidebar = try #require(menu(containing: "Show Sidebar") ?? menu(containing: "Hide Sidebar"))
		#expect(sidebar.keyEquivalent == "s" && sidebar.keyEquivalentModifierMask == [.control, .command])
	}

	@Test func searchNotesIsShiftCommandFBesideFindAndReplace() throws {
		let item = try #require(menu(containing: "Search Notes"))
		let replace = try #require(menu(containing: "Find and Replace…"))

		#expect(item.keyEquivalent == "f")
		#expect(item.keyEquivalentModifierMask == [.shift, .command])
		#expect(replace.keyEquivalentModifierMask == [.option, .command])
	}

	@Test func zoomInOutAndActualSizeAreInTheViewMenu() throws {
		let zoomIn = try #require(menu(containing: "Zoom In"))
		let zoomOut = try #require(menu(containing: "Zoom Out"))
		let actual = try #require(menu(containing: "Actual Size"))

		#expect(zoomIn.keyEquivalent == "+" && zoomIn.keyEquivalentModifierMask.contains(.command))
		#expect(zoomOut.keyEquivalent == "-" && zoomOut.keyEquivalentModifierMask == .command)
		#expect(actual.keyEquivalent == "0" && actual.keyEquivalentModifierMask == .command)
	}

	@Test(.writesStandardDefaults) func zoomingLeavesTheViewMenuWithOneSeparatorBetweenGroups() async throws {
		let view = try #require(menu(containing: "Zoom In")?.menu)
		let defaults = UserDefaults.standard
		let kept = defaults.object(forKey: EditorZoom.key)
		defer { defaults.set(kept, forKey: EditorZoom.key) }
		func choose(_ command: String) throws {
			view.performActionForItem(at: view.index(of: try #require(menu(containing: command))))
		}
		func storedZoom() -> Double {
			defaults.double(forKey: EditorZoom.key)
		}
		defaults.set(EditorZoom.larger(1), forKey: EditorZoom.key)
		try await settle {
			try choose("Actual Size")
			return storedZoom() == 1
		}

		for (command, zoom) in [("Zoom In", 1.2), ("Zoom In", 1.44), ("Zoom Out", 1.2), ("Actual Size", 1.0)] {
			try choose(command)
			try await settle { storedZoom() == zoom }
			try #require(storedZoom() == zoom, "\(command)")
		}
		NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSApp.mainMenu)

		let shown = view.items.filter { !$0.isHidden }
		#expect(shown.map { $0.isSeparatorItem ? "—" : $0.title } == ["Zoom In", "Zoom Out", "Actual Size", "—", "Show Toolbar", "Customize Toolbar…", "—", "Show Sidebar"])
	}

	@Test func aSeparatorNextToAnotherOrAtAnEndIsHidden() {
		let menu = NSMenu()
		for title in ["—", "A", "—", "—", "B", "—"] {
			menu.addItem(title == "—" ? .separator() : NSMenuItem(title: title, action: nil, keyEquivalent: ""))
		}

		MenuSeparators.hideDoubledAndEdgeSeparators(in: menu)

		#expect(menu.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "—" : $0.title } == ["A", "—", "B"])
	}

	@Test func syncNowIsCommandRInTheFileMenu() throws {
		let item = try #require(try fileMenu().item(withTitle: "Sync Now"))

		#expect(item.keyEquivalent == "r")
		#expect(item.keyEquivalentModifierMask == .command)
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

	@Test func lockIsCommandL() throws {
		let item = try #require(try fileMenu().item(withTitle: "Lock"))

		#expect(item.keyEquivalent == "l")
		#expect(item.keyEquivalentModifierMask == .command)
	}

	@Test func closingTheLastWindowKeepsTheAppRunning() throws {
		let delegate = try #require(NSApp.delegate)

		#expect(delegate.applicationShouldTerminateAfterLastWindowClosed?(NSApp) == false)
	}

	@Test func helpOpensTheGettingStartedGuide() throws {
		let item = try #require(menu(containing: "Native Note Help"))
		try #require(item.action != #selector(NSApplication.showHelp(_:)), "AppKit's own Help item shows an alert")
		let help = try #require(item.menu)
		var opened: [URL] = []
		let open = Guide.open
		Guide.open = { opened.append($0) }
		defer { Guide.open = open }

		help.performActionForItem(at: help.index(of: item))

		#expect(opened == [Guide.gettingStarted])
		#expect(Guide.gettingStarted.absoluteString == "https://git.hloth.dev/hloth/native-note/src/branch/main/docs/guides/getting-started.md")
		#expect(item.keyEquivalent == "?" && item.keyEquivalentModifierMask == .command)
	}

	@Test func libraryCommandsWaitForUnlock() throws {
		let file = try fileMenu()

		file.update()

		for title in ["New Note", "Lock", "Export…", "Import…"] {
			#expect(file.item(withTitle: title)?.isEnabled == false, "\(title)")
		}
	}
}
