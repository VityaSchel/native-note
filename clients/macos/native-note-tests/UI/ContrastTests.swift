import AppKit
import NativeNoteKit
import ObjectiveC
import SwiftUI
import Testing

@testable import NativeNote

@MainActor @Suite(.serialized, .takesFocus, .timeLimit(.minutes(10)))
struct ContrastTests {
	private func audit(_ view: some View, _ screen: String, width: CGFloat = 380, height: CGFloat = 620, attachingShortfalls: Bool = true) async throws -> ContrastAudit {
		let offscreen = OffscreenWindow(AnyView(view), width: width, height: height)
		defer { offscreen.close() }
		return try await offscreen.auditContrast(screen, attachingShortfalls: attachingShortfalls)
	}

	private func requireTheBlueAccent() throws {
		let accent = UserDefaults.standard.object(forKey: "AppleAccentColor").map { "\($0)" }
		try #require(accent == nil || accent == "4", "Readings on the emphasized selection assume the blue accent, which the native-note scheme pins with -AppleAccentColor 4")
	}

	private func phraseFields(_ typed: String) -> some View {
		var entry = PhraseEntry()
		_ = entry.set(typed, at: 0)
		return PhraseFields(entry: .constant(entry), submit: {})
			.textFieldStyle(.roundedBorder)
			.padding(20)
			.frame(width: 440)
	}

	@Test func theIncreasedContrastAppearancesLoadAndRaiseContrast() async throws {
		for dark in [false, true] {
			let standard = try #require(SystemContrast.appearance(dark: dark, increased: false))
			let increased = try #require(SystemContrast.appearance(dark: dark, increased: true))
			for color in [NSColor.secondaryLabelColor, .placeholderTextColor, .separatorColor] {
				func ratio(in appearance: NSAppearance) -> Double {
					var ratio = 0.0
					appearance.performAsCurrentDrawingAppearance {
						let background = RGBA(color: .windowBackgroundColor)
						ratio = RGBA(color: color).over(background).contrast(with: background)
					}
					return ratio
				}
				#expect(ratio(in: increased) > ratio(in: standard) + 0.5, "\(color) in \(dark ? "dark" : "light")")
			}
		}

		let audit = try await audit(
			VStack {
				Text("Secondary probe").foregroundStyle(.secondary)
				List { Text("Listed probe").foregroundStyle(.secondary) }
				SecureField("Password", text: .constant("")).capsuleField()
			}
			.padding(40),
			"liveness"
		)

		for name in ["Secondary probe", "Listed probe"] {
			for (standard, increased) in [(Appearance.light, Appearance.increasedLight), (.dark, .increasedDark)] {
				let before = try #require(audit.readings(of: name, in: standard).first)
				let after = try #require(audit.readings(of: name, in: increased).first)
				#expect(after.value > before.value + 1, "\(name): \(before.value) in \(standard), \(after.value) in \(increased)")
			}
		}
		for (standard, increased) in [(Appearance.light, Appearance.increasedLight), (.dark, .increasedDark)] {
			let before = try #require(audit.rings.first { $0.appearance == standard }).ratio
			let after = try #require(audit.rings.first { $0.appearance == increased }).ratio
			#expect(after > before + 1, "capsule outline: \(before) in \(standard), \(after) in \(increased)")
		}
		for (light, dark) in [(Appearance.light, Appearance.dark), (.increasedLight, .increasedDark)] {
			let lit = try #require(audit.readings(of: "Listed probe", in: light).first)
			let darkened = try #require(audit.readings(of: "Listed probe", in: dark).first)
			#expect(darkened.measurement.background.luminance < lit.measurement.background.luminance, "the list cell in \(light) and \(dark), drawn in one emulation")
		}
	}

	@Test func emulatingIncreaseContrastIsUndoneWhetherItsBodyReturnsOrThrows() throws {
		let named = try #require(class_getClassMethod(NSAppearance.self, NSSelectorFromString("appearanceNamed:")))
		let flag = try #require(class_getInstanceMethod(NSWorkspace.self, #selector(getter: NSWorkspace.accessibilityDisplayShouldIncreaseContrast)))
		let (namedBefore, flagBefore) = (method_getImplementation(named), method_getImplementation(flag))
		let increasedBefore = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
		func secondaryInAqua() -> RGBA {
			var resolved = RGBA(red: 0, green: 0, blue: 0)
			NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { resolved = RGBA(color: .secondaryLabelColor).over(RGBA(red: 1, green: 1, blue: 1)) }
			return resolved
		}
		let secondaryBefore = secondaryInAqua()
		func isRestored() -> Bool {
			method_getImplementation(named) == namedBefore && method_getImplementation(flag) == flagBefore && !SystemContrast.isEmulating
				&& NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast == increasedBefore && secondaryInAqua().matches(secondaryBefore)
		}

		let flagged = try SystemContrast.emulating(increased: true) { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast && SystemContrast.isEmulating }
		let secondaryWhileEmulating = try SystemContrast.emulating(increased: true) { secondaryInAqua() }
		#expect(flagged)
		#expect(!secondaryWhileEmulating.matches(secondaryBefore))
		#expect(isRestored())

		#expect(throws: CancellationError.self) {
			try SystemContrast.emulating(increased: true) { () throws -> Bool in throw CancellationError() }
		}
		#expect(isRestored())
	}

	@Test func theAuditFailsLowContrastTextAndIcons() async throws {
		var audit = ContrastAudit()
		await withKnownIssue("Pale gray text and a pale gray icon fall short on a light window") {
			audit = try await self.audit(
				VStack {
					Text("Pale text").foregroundStyle(Color(white: 0.82))
					Image(systemName: "star.fill").foregroundStyle(Color(white: 0.82)).accessibilityLabel("Pale icon")
				}
				.padding(40),
				"negative control",
				attachingShortfalls: false
			)
		}

		for appearance in [Appearance.light, .increasedLight] {
			let text = try #require(audit.readings(of: "Pale text", in: appearance).first)
			let icon = try #require(audit.readings(of: "Pale icon", in: appearance).first)
			#expect(text.value < 4.5 && !text.meetsThreshold && !text.mayFallShort, "\(text.description)")
			#expect(icon.value < 3 && !icon.meetsThreshold && !icon.mayFallShort, "\(icon.description)")
		}
	}

	@Test(arguments: ScreenGroup.allCases.filter(\.measuresContrast))
	func everyCatalogScreenMeetsContrast(_ group: ScreenGroup) async throws {
		try requireTheBlueAccent()
		var measured = 0
		for (index, screen) in group.screens.enumerated() where screen.measuresContrast {
			try await screen.whileShown { offscreen in
				let audit = try await offscreen.auditContrast("\(group) screen \(index + 1)")
				let counts = Appearance.allCases.map { appearance in audit.readings.count { $0.appearance == appearance } }

				#expect(Set(counts).count == 1, "\(group) screen \(index + 1) measured \(counts) elements in \(Appearance.allCases)")
				measured += counts[0]
			}
		}

		#expect(measured > 0)
	}

	@Test func theSetAnUnlockPasswordStepMeetsContrast() async throws {
		let offscreen = OffscreenWindow(
			AnyView(OnboardingView(libraryExists: false, createLibrary: { _ in nil }, hasSecureEnclave: false, announce: { _ in }, finish: {})),
			width: 720,
			height: 560
		)
		defer { offscreen.close() }
		try offscreen.press("Next")
		try offscreen.type("correct horse", into: "Password")
		let confirmation = try offscreen.type("battery staple", into: "Confirm Password")
		confirmation.currentEditor()?.insertNewline(nil)
		await offscreen.pump { offscreen.texts().contains("The passwords do not match.") }

		let audit = try await offscreen.auditContrast("Set an Unlock Password")

		for appearance in Appearance.allCases {
			let warning = try #require(audit.readings(of: "no Secure Enclave", in: appearance).first)
			#expect(warning.measurement.strongest >= 4.5, "the warning text in \(appearance): \(warning.description)")
			#expect(appearance.resolve(.systemOrange).over(warning.measurement.background).matches(warning.measurement.weakestInk), "the warning icon in \(appearance): \(warning.description)")
		}
		for appearance in [Appearance.increasedLight, .increasedDark] {
			let warning = try #require(audit.readings(of: "no Secure Enclave", in: appearance).first)
			let mismatch = try #require(audit.readings(of: "The passwords do not match.", in: appearance).first)

			#expect(warning.measurement.weakest >= 3, "the warning icon in \(appearance): \(warning.description)")
			#expect(mismatch.value >= 4.5, "\(mismatch.description)")
			#expect(appearance.resolve(.systemRed).over(mismatch.measurement.background).matches(mismatch.measurement.weakestInk), "\(mismatch.description)")
			#expect(audit.rings.filter { $0.appearance == appearance }.map(\.ratio).count == 2)
			#expect(audit.rings.filter { $0.appearance == appearance }.allSatisfy { $0.ratio >= 3 })
		}
		for appearance in [Appearance.light, .dark] {
			let rings = audit.rings.filter { $0.appearance == appearance }.map(\.ratio)
			#expect(rings.count == 2 && rings.allSatisfy { $0 < 2 }, "the capsule outline stays a separator hairline in \(appearance): \(rings)")
		}
	}

	@Test func redErrorTextReachesFourAndAHalfWithIncreaseContrast() async throws {
		let refused = try await audit(ImportPassphraseSheet(refused: true, working: false, submit: { _ in }, cancel: {}), "refused import")
		let checksum = try await audit(phraseFields(Array(repeating: "abandon", count: PhraseEntry.count).joined(separator: " ")), "checksum", width: 440, height: 360)
		let unknown = try await audit(phraseFields("zzzz"), "unknown word", width: 440, height: 360)

		for appearance in [Appearance.increasedLight, .increasedDark] {
			let lines = try [
				#require(refused.readings(of: "Wrong passphrase", in: appearance).first),
				#require(checksum.readings(of: PhraseFields.checksumMessage, in: appearance).first),
			]
			for line in lines {
				#expect(line.value >= 4.5, "\(line.description)")
				#expect(appearance.resolve(.systemRed).over(line.measurement.background).matches(line.measurement.weakestInk), "\(line.description)")
			}
			let word = try #require(unknown.readings(of: "zzzz", in: appearance).first)
			let mark = try #require(unknown.readings(of: PhraseFields.unknownWordLabel, in: appearance).first)

			#expect(word.value >= 4.5, "\(word.description)")
			#expect(mark.value >= 3, "\(mark.description)")
			#expect(appearance.resolve(.systemRed).over(mark.measurement.background).matches(mark.measurement.weakestInk), "\(mark.description)")
		}
	}

	@Test func theSelectedNotePreviewReadsOnTheEmphasizedSelectionWithIncreaseContrast() async throws {
		try requireTheBlueAccent()
		let selected = NoteGroup.samples[0].notes[0]
		let audit = try await audit(
			NavigationStack {
				NoteListView(groups: NoteGroup.samples, now: Note.sampleNow, selection: .constant(selected.id), search: .constant("")) { _ in }
			},
			"selected note",
			width: 300,
			height: 460
		)
		let title = NoteRow(note: selected, now: Note.sampleNow).displayTitle

		func emphasizedRow(in appearance: Appearance) throws -> ContrastReading {
			try #require(audit.readings.first { $0.element.name.contains(title) && $0.appearance == appearance && $0.emphasized })
		}

		for appearance in [Appearance.increasedLight, .increasedDark] {
			let row = try emphasizedRow(in: appearance)
			let unemphasized = try #require(audit.readings(of: title, in: appearance).first)

			#expect(appearance.resolve(.selectedContentBackgroundColor).matches(row.measurement.background), "\(row.description)")
			#expect(row.value >= 4.5, "\(row.description)")
			#expect(row.measurement.weakest > row.measurement.strongest - 1, "the preview reads as primary: \(row.description)")
			#expect(unemphasized.measurement.weakest < unemphasized.measurement.strongest - 1, "the preview stays secondary off the emphasized selection: \(unemphasized.description)")
		}
		for appearance in [Appearance.light, .dark] {
			let row = try emphasizedRow(in: appearance)
			#expect(row.measurement.weakest < row.measurement.strongest - 1, "the preview stays secondary without Increase Contrast: \(row.description)")
		}
	}
}
