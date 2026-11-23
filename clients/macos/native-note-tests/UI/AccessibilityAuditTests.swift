import AppKit
import SwiftUI
import Testing

@testable import NativeNote
@testable import NativeNoteKit

enum SheetCase: String, CaseIterable, CustomTestStringConvertible {
	case changePassword, turnOnTouchID, setUpSync, changeServer, changeRecoveryPhrase, turnOffSync, onboardingSetUpSync
	case eraseNotes, failureAlert, export, importPassphrase, importSummary

	var testDescription: String { rawValue }

	// AppKit ends an alert through its sheet parent, which a caught sheet lacks, so an alert is checked up to the button its key reaches.
	var isAlert: Bool {
		[.turnOffSync, .eraseNotes, .failureAlert, .importSummary].contains(self)
	}

	var closesWithReturn: Bool {
		[.failureAlert, .importSummary].contains(self)
	}
}

@MainActor @Suite(.timeLimit(.minutes(10)))
struct AccessibilityAuditTests {
	private let server = "http://notes.example:8080/"

	@Test(.takesFocus, .serialized, arguments: ScreenGroup.allCases)
	func everyScreenNamesItsControlsSpeaksWhatItShowsAndHidesItsDecoration(_ group: ScreenGroup) async throws {
		let screens = group.screens
		#expect(!screens.isEmpty)
		for (index, screen) in screens.enumerated() {
			try await screen.whileShown { offscreen in
				let findings = try await offscreen.audit(expecting: screen.expectations)

				#expect(findings.isEmpty, "\(group) screen \(index + 1):\n\(findings.map(\.description).joined(separator: "\n"))")
			}
		}
	}

	@Test(.takesFocus) func theAuditFindsEachKindOfProblemItLooksFor() async throws {
		let offscreen = OffscreenWindow(AnyView(FlawedScreen()), width: 380, height: 620)
		defer { offscreen.close() }
		offscreen.pump(for: 0.05)
		let looping = NSAccessibilityElement()
		let inner = NSAccessibilityElement()
		inner.setAccessibilityRole(.group)
		inner.setAccessibilityLabel("Inner")
		looping.setAccessibilityRole(.group)
		looping.setAccessibilityChildren([inner])
		inner.setAccessibilityChildren([looping])
		defer { inner.setAccessibilityChildren(nil) }

		let findings = try await offscreen.audit(expecting: AuditExpectations(mustHear: ["Never shown anywhere"], mustNotHear: [FlawedScreen.title]))
			+ AccessibilityAudit.findings(in: [AttributeElement.walk(from: looping)], expecting: AuditExpectations())
			+ AccessibilityAudit.findings(in: [AccessibilityWalk()], expecting: AuditExpectations())
		func found(_ rule: AuditRule, _ matches: (AuditFinding) -> Bool) -> Bool {
			findings.contains { $0.rule == rule && matches($0) }
		}

		#expect(Set(findings.map(\.rule)) == Set(AuditRule.allCases), "\(findings)")
		#expect(found(.unnamedControl) { $0.role == "AXButton" && $0.name.isEmpty })
		#expect(found(.placeholderOnlyName) { $0.detail.contains(FlawedScreen.prompt) })
		#expect(found(.roleWordInName) { $0.name == "Delete Button" })
		#expect(found(.rawIdentifierName) { $0.name == "x.squareroot" })
		#expect(found(.reachableDecorativeImage) { $0.role == "AXImage" })
		#expect(found(.unhiddenSpinner) { _ in true })
		#expect(found(.notPressable) { $0.name == InertButtonView.name })
		#expect(found(.missingText) { $0.name == "Never shown anywhere" })
		#expect(found(.missingText) { AccessibilityAudit.normalized($0.name).contains("shown but never spoken") })
		#expect(found(.missingText) { AccessibilityAudit.normalized($0.name).contains("save the flawed screen") })
		#expect(found(.unexpectedText) { $0.name == FlawedScreen.title })
		#expect(found(.duplicateButtonName) { $0.name == "Save" })
		#expect(found(.loop) { $0.role == "AXGroup" })
		#expect(found(.emptyTree) { _ in true })
	}

	@Test(.takesFocus, .serialized, arguments: SheetCase.allCases)
	func everySheetClosesWithEscapeAndEveryOKOnlyAlertWithReturn(_ sheetCase: SheetCase) async throws {
		let offscreen = try present(sheetCase)
		defer { offscreen.close() }
		await offscreen.pump { offscreen.sheet != nil }
		let sheet = try #require(offscreen.sheet)
		offscreen.pump(for: 0.05)

		let key = sheetCase.closesWithReturn ? "\r" : "\u{1b}"
		#expect(try sheetCase.closesWithReturn ? offscreen.pressReturn(in: sheet) : offscreen.pressEscape(in: sheet))
		if sheetCase.isAlert {
			#expect(offscreen.sheetViews(of: NSButton.self).contains { $0.keyEquivalent == key })
		} else {
			await offscreen.pump { offscreen.sheet == nil }
			#expect(offscreen.sheet == nil)
		}
	}

	@Test(.takesFocus) func escapeLeavesASheetWithoutACancelButtonOpen() async throws {
		let offscreen = OffscreenWindow(AnyView(Color.clear.sheet(isPresented: .constant(true)) { Text("No way out").padding(40) }), catchesSheets: true)
		defer { offscreen.close() }
		await offscreen.pump { offscreen.sheet != nil }
		let sheet = try #require(offscreen.sheet)

		#expect(try !offscreen.pressEscape(in: sheet))
		offscreen.pump(for: 0.2)
		#expect(offscreen.sheet === sheet)
	}

	@Test func drawnTextIgnoresMisreadsThatFuseLettersAndDigitsButNotWordsOrNumbers() {
		#expect(AccessibilityAudit.isSpoken("13. Reve84..", from: []))
		#expect(!AccessibilityAudit.isSpoken("Reveal the words", from: []))
		#expect(!AccessibilityAudit.isSpoken("2026.08.06 at 10:42", from: []))
		#expect(AccessibilityAudit.isSpoken("2026.08.06 at 10:42", from: ["2026"]))
	}

	@Test func theMenuBarNamesEveryCommandWithoutRoleWordsOrSymbolNames() throws {
		var titles: [String] = []
		func read(_ menu: NSMenu) {
			for item in menu.items where !item.isSeparatorItem && !item.isHidden {
				titles.append(item.title)
				item.submenu.map(read)
			}
		}
		read(try #require(NSApp.mainMenu))

		for command in ["New Note", "Sync Now", "Lock", "Export…", "Import…", "Search Notes", "Zoom In", "Zoom Out", "Actual Size", "Native Note Help"] {
			#expect(titles.contains(command), "\(command)")
		}
		#expect(!titles.contains(""))
		#expect(titles.filter(AccessibilityAudit.containsRoleWord).isEmpty)
		#expect(titles.filter(AccessibilityAudit.isRawIdentifier).isEmpty)
	}

	@Test(.takesFocus) func theTouchIDSwitchSpeaksWhetherItIsOn() async throws {
		func settings(touchIDEnabled: Bool) -> AnyView {
			AnyView(SecuritySettings.stubbed(touchIDEnabled: touchIDEnabled))
		}
		let offscreen = OffscreenWindow(settings(touchIDEnabled: false), width: 440, height: 300)
		defer { offscreen.close() }
		func touchID() -> AttributeElement? {
			offscreen.attributeTree().first { $0.role == "AXCheckBox" && $0.name.hasPrefix("Touch ID") }
		}

		let off = try #require(touchID())
		offscreen.host.rootView = settings(touchIDEnabled: true)
		offscreen.pump(for: 0.05)
		let on = try #require(touchID())

		#expect(off.value == "0")
		#expect(on.value == "1")
		#expect(on.subrole == "AXSwitch")
	}

	private func present(_ sheetCase: SheetCase) throws -> OffscreenWindow<AnyView> {
		func settings(_ status: AppModel.SyncStatus = AppModel.SyncStatus()) -> AnyView {
			AnyView(SecuritySettings.stubbed(status: status))
		}
		let notes = NoteGroup.samples.flatMap(\.notes)
		func library(_ model: AppModel? = nil, _ change: (LibraryExchange) -> Void = { _ in }) -> OffscreenWindow<AnyView> {
			let model = model ?? .previewing(notes)
			let exchange = LibraryExchange(model: model)
			let offscreen = OffscreenWindow(AnyView(ContentView(exchange: exchange, announce: { _ in }, syncAnnouncements: SyncAnnouncements())), width: 980, height: 560, catchesSheets: true)
			change(exchange)
			return offscreen
		}
		let synced = AppModel.SyncStatus(phase: .idle, server: server)
		switch sheetCase {
		case .changePassword:
			return try presenting(settings(), by: "Change Password…")
		case .turnOnTouchID:
			let offscreen = OffscreenWindow(settings(), width: 440, height: 400, catchesSheets: true)
			try #require(offscreen.views(of: NSSwitch.self).first).performClick(nil)
			return offscreen
		case .setUpSync:
			return try presenting(settings(), by: "Set Up Sync…")
		case .changeServer:
			return try presenting(settings(synced), by: "Change Server…")
		case .changeRecoveryPhrase:
			return try presenting(settings(synced), by: "Change Recovery Phrase…")
		case .turnOffSync:
			return try presenting(settings(synced), by: "Turn Off Sync…")
		case .onboardingSetUpSync:
			return try presenting(AnyView(OnboardingView(libraryExists: true, createLibrary: { _ in nil }, announce: { _ in }, finish: {})), by: "Set Up", width: 720, height: 560)
		case .eraseNotes:
			let offscreen = OffscreenWindow(AnyView(UnlockView(failure: .wrongPassword, submit: { _ in nil }, dismissFailure: {}, eraseLibrary: {}, announce: { _ in })), catchesSheets: true)
			try offscreen.pressLink("Forgot Password?")
			return offscreen
		case .failureAlert:
			return library(.previewing(notes, failure: .unsaved("disk I/O error")))
		case .export:
			return library { $0.isExporting = true }
		case .importPassphrase:
			return OffscreenWindow(AnyView(ImportPassphrasePresenter()), catchesSheets: true)
		case .importSummary:
			return library { $0.lastImport = ImportSummary(added: 3) }
		}
	}

	private func presenting(_ view: AnyView, by button: String, width: CGFloat = 440, height: CGFloat = 520) throws -> OffscreenWindow<AnyView> {
		let offscreen = OffscreenWindow(view, width: width, height: height, catchesSheets: true)
		try offscreen.press(button)
		return offscreen
	}
}

private struct ImportPassphrasePresenter: View {
	@State private var shown = true

	var body: some View {
		Color.clear.sheet(isPresented: $shown) {
			ImportPassphraseSheet(refused: false, working: false, submit: { _ in }, cancel: { shown = false })
		}
	}
}

private struct FlawedScreen: View {
	static let title = "Flawed screen"
	static let prompt = "Nickname"
	static let wordsSpokenElsewhere = "Save the flawed screen"

	@State private var nickname = ""

	var body: some View {
		VStack(spacing: 12) {
			Text(Self.title)
			Button {} label: { Color.gray.frame(width: 24, height: 24) }
			Button("Delete Button") {}
			Button("Save") {}
			Button("Save") {}
			Button {} label: { Image(systemName: "x.squareroot") }
				.accessibilityLabel("x.squareroot")
			Image(systemName: "star.fill")
			ProgressView()
			TextField("", text: $nickname, prompt: Text(Self.prompt))
			Text("Shown but never spoken")
				.font(.title2)
				.accessibilityHidden(true)
			InertButton()
				.frame(width: 60, height: 24)
			Text(Self.wordsSpokenElsewhere)
				.font(.title2)
				.accessibilityHidden(true)
				.padding(.top, 24)
		}
		.padding(20)
	}
}

private struct InertButton: NSViewRepresentable {
	func makeNSView(context: Context) -> InertButtonView {
		InertButtonView()
	}

	func updateNSView(_ view: InertButtonView, context: Context) {}
}

private final class InertButtonView: NSView {
	static let name = "Inert"

	override func isAccessibilityElement() -> Bool { true }

	override func accessibilityRole() -> NSAccessibility.Role? { .button }

	override func accessibilityLabel() -> String? { Self.name }

	override func isAccessibilityEnabled() -> Bool { true }

	override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
		selector != #selector(accessibilityPerformPress) && super.isAccessibilitySelectorAllowed(selector)
	}
}
