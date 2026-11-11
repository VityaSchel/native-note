import AppKit
import CryptoKit
@testable import NativeNoteKit
import Testing

@testable import NativeNote

@MainActor
private final class Calls {
	var prepared: [[String]] = []
	var finished: [[String]] = []
	var joined: [[String]] = []
	var rotations = 0
	var adopted: [String] = []
	var cancelled = 0
	var done = 0
	var announced: [String] = []
}

private let realWords = Mnemonic.words(for: .init(data: Data((0 ..< 32).map { UInt8($0 * 5 + 1) }))) ?? []
private let phrase = AppModel.RecoveryPhrase(words: realWords, checked: [2, 10, 19])
private let checkedWords = [2, 10, 19].map { realWords[$0] }
private let numberedList = realWords.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")

@MainActor @Suite(.takesFocus)
struct SyncSetupViewTests {
	private func offscreen(
		_ mode: SyncSetupForm.Mode,
		_ calls: Calls,
		prepare: Result<AppModel.SyncSetupStart, AppModel.SyncSetupFailure> = .success(.newLibrary(phrase)),
		finish: AppModel.SyncSetupFailure? = nil,
		join: AppModel.SyncSetupFailure? = nil,
		adopt: AppModel.SyncSetupFailure? = nil,
		clipboard: RecoveryClipboard = RecoveryClipboard(NSPasteboard(name: .init("dev.hloth.nativenote.tests.unused"))),
		server: String = ""
	) -> OffscreenWindow<SyncSetupView> {
		let controls = SyncControls(
			prepareSync: { server, key in
				calls.prepared.append([server, key])
				return prepare
			},
			finishSync: { answers in
				calls.finished.append(answers)
				return finish
			},
			joinSync: { server, key, entry in
				calls.joined.append([server, key] + entry.words)
				return join
			},
			prepareRotation: {
				calls.rotations += 1
				return phrase
			},
			finishRotation: { answers in
				calls.finished.append(answers)
				return finish
			},
			adoptCurrentPhrase: { text in
				calls.adopted.append(text)
				return adopt
			},
			cancel: { calls.cancelled += 1 }
		)
		return OffscreenWindow(
			SyncSetupView(form: SyncSetupForm(mode: mode, server: server), controls: controls, clipboard: clipboard, announce: { calls.announced.append($0) }, done: { calls.done += 1 }),
			width: 440,
			height: 560
		)
	}

	private func wordFields(_ offscreen: OffscreenWindow<SyncSetupView>) -> [NSTextField] {
		offscreen.views(of: NSTextField.self).filter(\.isEditable).sorted {
			let (first, second) = (offscreen.onScreen($0), offscreen.onScreen($1))
			return abs(first.minX - second.minX) > 1 ? first.minX < second.minX : first.maxY > second.maxY
		}
	}

	private func typeKeys(_ keys: String, into field: NSTextField, of offscreen: OffscreenWindow<SyncSetupView>) throws {
		if field.currentEditor() == nil {
			try #require(offscreen.window.makeFirstResponder(field))
			try #require(field.currentEditor()).moveToEndOfDocument(nil)
		}
		for key in keys {
			try #require(field.currentEditor()).insertText(String(key))
			offscreen.pump()
		}
	}

	private func isRed(_ field: NSTextField) -> Bool {
		guard let color = field.textColor?.usingColorSpace(.sRGB), let red = NSColor.systemRed.usingColorSpace(.sRGB) else { return false }
		return abs(color.redComponent - red.redComponent) < 0.05 && abs(color.greenComponent - red.greenComponent) < 0.05
			&& abs(color.blueComponent - red.blueComponent) < 0.05
	}

	private func editing(_ offscreen: OffscreenWindow<SyncSetupView>) -> NSTextField? {
		(offscreen.window.firstResponder as? NSText)?.delegate as? NSTextField
	}

	private func reachJoin(_ offscreen: OffscreenWindow<SyncSetupView>) async throws -> [NSTextField] {
		try type("http://notes.example", into: try #require(fields(offscreen).first { !($0 is NSSecureTextField) }), of: offscreen)
		let key = try #require(offscreen.views(of: NSSecureTextField.self).first)
		try type("0a", into: key, of: offscreen)
		key.currentEditor()?.insertNewline(nil)
		await offscreen.pump { texts(offscreen).contains("Enter Your Recovery Phrase") && wordFields(offscreen).count == 24 }
		await offscreen.pump { editing(offscreen) === wordFields(offscreen).first }
		return wordFields(offscreen)
	}

	private func onWords(_ offscreen: OffscreenWindow<SyncSetupView>) -> Bool {
		texts(offscreen).contains("Write Down Your Recovery Phrase")
	}

	private func button(_ label: String, in offscreen: OffscreenWindow<SyncSetupView>) -> AccessibilityElement? {
		offscreen.accessibilityElements(.button).first { $0.label == label }
	}

	private func isEnabled(_ label: String, in offscreen: OffscreenWindow<SyncSetupView>) -> Bool {
		offscreen.accessibilityElements(.button).first { $0.label == label }?.isEnabled == true
	}

	private func fields(_ offscreen: OffscreenWindow<SyncSetupView>) -> [NSTextField] {
		offscreen.views(of: NSTextField.self).filter(\.isEditable).sorted { offscreen.onScreen($0).maxY > offscreen.onScreen($1).maxY }
	}

	private func type(_ text: String, into field: NSTextField, of offscreen: OffscreenWindow<SyncSetupView>) throws {
		try #require(offscreen.window.makeFirstResponder(field))
		try #require(field.currentEditor()).insertText(text)
		offscreen.pump()
	}

	/// Static text and the sheet's title, which VoiceOver reads as a heading.
	private func texts(_ offscreen: OffscreenWindow<SyncSetupView>) -> [String] {
		offscreen.accessibilityElements().filter { [.staticText, NSAccessibility.Role(rawValue: "AXHeading")].contains($0.role) }.map { $0.value.isEmpty ? $0.label : $0.value }
	}

	private func press(_ label: String, in offscreen: OffscreenWindow<SyncSetupView>) throws {
		try #require(offscreen.accessibilityElements(.button).first { $0.label == label }).press()
		offscreen.pump()
	}

	@Test func theServerStepNamesOnlyItsFields() {
		let offscreen = offscreen(.setUp, Calls())
		defer { offscreen.close() }
		offscreen.pump()

		#expect(!texts(offscreen).contains { $0.contains("api-key file") })
	}

	@Test func setupTakesTheServerShowsTheWordsAndChecksThreeBeforeTurningSyncOn() async throws {
		let calls = Calls()
		let offscreen = offscreen(.setUp, calls)
		defer { offscreen.close() }

		let server = try #require(fields(offscreen).first { !($0 is NSSecureTextField) })
		let key = try #require(offscreen.views(of: NSSecureTextField.self).first)
		try type("http://notes.example:8080", into: server, of: offscreen)
		try type("0a0b", into: key, of: offscreen)
		key.currentEditor()?.insertNewline(nil)
		await offscreen.pump { onWords(offscreen) }
		#expect(calls.prepared == [["http://notes.example:8080", "0a0b"]])
		#expect(!texts(offscreen).contains { $0.contains(realWords[23]) })

		try press("Continue", in: offscreen)
		let answers = fields(offscreen)
		#expect(answers.count == 3)
		for (field, word) in zip(answers, checkedWords) {
			try type(word, into: field, of: offscreen)
		}
		try press("Turn On Sync", in: offscreen)
		await offscreen.pump { calls.done > 0 }

		#expect(calls.finished == [checkedWords])
		#expect(calls.cancelled == 0)
	}

	@Test func copiedWordsAreConcealedAndOutlastConfirmingThePhrase() async throws {
		let pasteboard = NSPasteboard(name: .init("dev.hloth.nativenote.tests.\(UUID().uuidString)"))
		defer { pasteboard.releaseGlobally() }
		let calls = Calls()
		let offscreen = offscreen(.rotate, calls, clipboard: RecoveryClipboard(pasteboard))
		await offscreen.pump { onWords(offscreen) }

		try press("Copy Words", in: offscreen)
		#expect(pasteboard.string(forType: .string) == numberedList)
		#expect(Set(pasteboard.types ?? []).isSuperset(of: [RecoveryClipboard.concealed, RecoveryClipboard.transient]))
		offscreen.pump(for: 0.1)
		#expect(!texts(offscreen).contains { $0.hasPrefix("Copied") })
		try press("Continue", in: offscreen)
		for (field, word) in zip(fields(offscreen), checkedWords) {
			try type(word, into: field, of: offscreen)
		}
		try press("Change Phrase", in: offscreen)
		await offscreen.pump { calls.done > 0 }
		offscreen.close()

		#expect(calls.done == 1)
		#expect(pasteboard.string(forType: .string) == numberedList)
	}

	@Test func changingToAServerThatHoldsThisLibraryClosesWithoutWords() async throws {
		let calls = Calls()
		let offscreen = offscreen(.changeServer, calls, prepare: .success(.reattached), server: "http://old.example:8080")
		defer { offscreen.close() }
		#expect(texts(offscreen).contains("Change Server"))
		#expect(texts(offscreen).contains { $0.contains("its API key, also after the server moved or its key was replaced") })
		let address = try #require(fields(offscreen).first { !($0 is NSSecureTextField) })
		#expect(address.stringValue == "http://old.example:8080")

		let key = try #require(offscreen.views(of: NSSecureTextField.self).first)
		try type("0a0b", into: key, of: offscreen)
		try press("Continue", in: offscreen)
		await offscreen.pump { calls.done > 0 }

		#expect(calls.prepared == [["http://old.example:8080", "0a0b"]])
		#expect(calls.done == 1)
		#expect(calls.finished.isEmpty)
	}

	@Test func movingToAnEmptyServerChecksTheNewWordsAndMovesTheLibrary() async throws {
		let calls = Calls()
		let offscreen = offscreen(.changeServer, calls, server: "http://old.example:8080")
		defer { offscreen.close() }
		let key = try #require(offscreen.views(of: NSSecureTextField.self).first)
		try type("0a0b", into: key, of: offscreen)
		try press("Continue", in: offscreen)
		await offscreen.pump { onWords(offscreen) }
		try press("Continue", in: offscreen)
		for (field, word) in zip(fields(offscreen), checkedWords) {
			try type(word, into: field, of: offscreen)
		}

		try press("Move Library", in: offscreen)
		await offscreen.pump { calls.done > 0 }

		#expect(calls.finished == [checkedWords])
		#expect(calls.rotations == 0)
		#expect(calls.done == 1)
	}

	@Test func aConfirmWordOffTheListTurnsRedAndHoldsTheCheckWithoutALine() async throws {
		let calls = Calls()
		let offscreen = offscreen(.rotate, calls)
		defer { offscreen.close() }
		await offscreen.pump { onWords(offscreen) }
		try press("Continue", in: offscreen)
		let answers = fields(offscreen)
		for (field, word) in zip(answers, checkedWords) {
			try type(word, into: field, of: offscreen)
		}
		#expect(isEnabled("Change Phrase", in: offscreen))

		try type("ab", into: answers[0], of: offscreen)
		#expect(!isRed(answers[0]))
		#expect(!isEnabled("Change Phrase", in: offscreen))
		try type("zzzz", into: answers[0], of: offscreen)
		await offscreen.pump { isRed(answers[0]) }

		#expect(isRed(answers[0]))
		#expect(!isEnabled("Change Phrase", in: offscreen))
		#expect(!texts(offscreen).contains { $0.contains("recovery word list") })
		#expect(calls.announced == ["Word 3 is not in the recovery word list."])
		answers[0].currentEditor()?.insertNewline(nil)
		offscreen.pump()
		#expect(calls.finished.isEmpty)
	}

	@Test func theWordsStayBlurredBehindAWarningUntilRevealedThenReadDownEachColumn() async throws {
		let offscreen = offscreen(.rotate, Calls())
		defer { offscreen.close() }
		await offscreen.pump { onWords(offscreen) }
		let columns = (0 ..< 3).map { column in
			(column * 8 + 1 ... column * 8 + 8).map { number in (column == 1 && number < 10 ? "\u{2007}" : "") + "\(number). \(realWords[number - 1])" }.joined(separator: "\n")
		}

		#expect(texts(offscreen).contains(RecoveryWords.warning))
		#expect(texts(offscreen).contains("These words are used to encrypt your notes on your sync server. Keep them safe and never share with anyone."))
		#expect(!texts(offscreen).contains { text in columns.contains { text.contains($0.prefix(12)) } })
		#expect(button("Copy Words", in: offscreen) != nil)

		try press("Reveal", in: offscreen)
		await offscreen.pump { !offscreen.views(of: RecoveryColumnsView.self).isEmpty }

		let view = try #require(offscreen.views(of: RecoveryColumnsView.self).first)
		let shown = view.columns.map { column in
			let layout = try! #require(column.layoutManager)
			let range = layout.characterRange(forGlyphRange: layout.glyphRange(for: try! #require(column.textContainer)), actualGlyphRange: nil)
			return (column.string as NSString).substring(with: range).trimmingCharacters(in: .newlines)
		}
		#expect(shown == columns)
		#expect(view.columns[1].frame.minX > view.columns[0].frame.maxX)
		#expect(texts(offscreen).contains(numberedList))
		#expect(!texts(offscreen).contains(RecoveryWords.warning))
		#expect(button("Reveal", in: offscreen) == nil)
	}

	@Test func aDragFromOneColumnIntoTheNextSelectsAcrossAndCopiesPlainNumberedLines() async throws {
		let offscreen = offscreen(.rotate, Calls())
		defer { offscreen.close() }
		await offscreen.pump { onWords(offscreen) }
		try press("Reveal", in: offscreen)
		await offscreen.pump { !offscreen.views(of: RecoveryColumnsView.self).isEmpty }
		let view = try #require(offscreen.views(of: RecoveryColumnsView.self).first)
		let pasteboard = NSPasteboard(name: .init("dev.hloth.nativenote.tests.\(UUID().uuidString)"))
		defer { pasteboard.releaseGlobally() }
		func lineMid(_ number: Int, edge: KeyPath<NSRect, CGFloat>) throws -> NSPoint {
			let column = view.columns[(number - 1) / 8]
			let layout = try #require(column.layoutManager)
			let lines = column.string.components(separatedBy: "\n")
			let start = lines.prefix(number - 1).reduce(0) { $0 + ($1 as NSString).length + 1 }
			let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: start, length: (lines[number - 1] as NSString).length), actualCharacterRange: nil)
			let rect = layout.boundingRect(forGlyphRange: glyphs, in: try #require(column.textContainer))
			return column.convert(NSPoint(x: rect[keyPath: edge], y: rect.midY), to: nil)
		}
		func send(_ type: NSEvent.EventType, at point: NSPoint, clicks: Int = 1) throws {
			let event = try #require(NSEvent.mouseEvent(
				with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: offscreen.window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
			))
			switch type {
			case .leftMouseDown: view.mouseDown(with: event)
			case .leftMouseDragged: view.mouseDragged(with: event)
			default: view.mouseUp(with: event)
			}
		}
		func copied() -> String? {
			pasteboard.clearContents()
			_ = view.columns[0].writeSelection(to: pasteboard, types: [.string])
			return pasteboard.string(forType: .string)
		}

		try send(.leftMouseDown, at: lineMid(2, edge: \.minX))
		try send(.leftMouseDragged, at: lineMid(6, edge: \.maxX))
		try send(.leftMouseDragged, at: lineMid(11, edge: \.maxX))
		try send(.leftMouseUp, at: lineMid(11, edge: \.maxX))

		#expect(copied() == (2 ... 11).map { "\($0). \(realWords[$0 - 1])" }.joined(separator: "\n"))

		var insideWord = try lineMid(20, edge: \.maxX)
		insideWord.x -= 4
		try send(.leftMouseDown, at: insideWord, clicks: 2)
		#expect(copied() == realWords[19])

		view.columns[0].selectAll(nil)
		#expect(copied() == numberedList)
	}

	@Test func cancelSitsAtTheLeadingEdgeApartFromBackAndTheNextStep() async throws {
		let offscreen = offscreen(.rotate, Calls())
		defer { offscreen.close() }
		await offscreen.pump { onWords(offscreen) }
		let words = try #require(button("Cancel", in: offscreen)).frame
		let next = try #require(button("Continue", in: offscreen)).frame
		#expect(next.minX - words.maxX > 200)

		try press("Continue", in: offscreen)
		await offscreen.pump { button("Back", in: offscreen) != nil }
		let cancel = try #require(button("Cancel", in: offscreen)).frame
		let back = try #require(button("Back", in: offscreen)).frame
		let change = try #require(button("Change Phrase", in: offscreen)).frame

		#expect(abs(cancel.minX - words.minX) < 1)
		#expect(back.minX - cancel.maxX > 100)
		#expect(change.minX > back.maxX && change.minX - back.maxX < 20)
	}

	@Test func cancelDuringTheServerCheckStopsItAndCloses() async throws {
		let calls = Calls()
		let stopped = Latch()
		let controls = SyncControls(prepareSync: { _, _ in
			try? await Task.sleep(for: .seconds(600))
			if Task.isCancelled { stopped.release() }
			return .failure(.refused)
		})
		let offscreen = OffscreenWindow(SyncSetupView(mode: .setUp, controls: controls, done: { calls.done += 1 }), width: 440, height: 560)
		defer { offscreen.close() }
		try type("http://notes.example:8080", into: try #require(fields(offscreen).first { !($0 is NSSecureTextField) }), of: offscreen)
		try type("0a0b", into: try #require(offscreen.views(of: NSSecureTextField.self).first), of: offscreen)
		try press("Continue", in: offscreen)
		await offscreen.pump { !isEnabled("Continue", in: offscreen) }
		#expect(isEnabled("Cancel", in: offscreen))

		try press("Cancel", in: offscreen)
		await stopped.wait()

		#expect(calls.done == 1)
	}

	@Test func cancelIsOffWhileThePhraseIsStored() async throws {
		let controls = SyncControls(
			prepareSync: { _, _ in .success(.newLibrary(phrase)) },
			finishSync: { _ in
				try? await Task.sleep(for: .seconds(600))
				return nil
			}
		)
		let offscreen = OffscreenWindow(SyncSetupView(mode: .setUp, controls: controls, done: {}), width: 440, height: 560)
		defer { offscreen.close() }
		try type("http://notes.example:8080", into: try #require(fields(offscreen).first { !($0 is NSSecureTextField) }), of: offscreen)
		try type("0a0b", into: try #require(offscreen.views(of: NSSecureTextField.self).first), of: offscreen)
		try press("Continue", in: offscreen)
		await offscreen.pump { onWords(offscreen) }
		try press("Continue", in: offscreen)
		for (field, word) in zip(fields(offscreen), checkedWords) {
			try type(word, into: field, of: offscreen)
		}

		try press("Turn On Sync", in: offscreen)
		await offscreen.pump { !isEnabled("Cancel", in: offscreen) }

		#expect(!isEnabled("Cancel", in: offscreen))
	}

	@Test func theConfirmStepNamesTheWordsToEnter() async throws {
		let calls = Calls()
		let offscreen = offscreen(.rotate, calls)
		defer { offscreen.close() }
		await offscreen.pump { onWords(offscreen) }

		try press("Continue", in: offscreen)
		await offscreen.pump { texts(offscreen).contains("Enter words 3, 11 and 20 from the phrase you wrote down.") }

		#expect(texts(offscreen).contains("Enter words 3, 11 and 20 from the phrase you wrote down."))
		#expect(SyncSetupView.list([7]) == "7")
		#expect(SyncSetupView.list([1, 2]) == "1 and 2")
	}

	@Test func somethingCopiedOverTheWordsStaysWhenTheSheetCloses() async throws {
		let pasteboard = NSPasteboard(name: .init("dev.hloth.nativenote.tests.\(UUID().uuidString)"))
		defer { pasteboard.releaseGlobally() }
		let calls = Calls()
		let clipboard = RecoveryClipboard(pasteboard)
		let offscreen = offscreen(.rotate, calls, clipboard: clipboard)
		await offscreen.pump { onWords(offscreen) }

		try press("Copy Words", in: offscreen)
		pasteboard.clearContents()
		pasteboard.setString("mine", forType: .string)
		try press("Continue", in: offscreen)
		offscreen.close()
		clipboard.clear()

		#expect(pasteboard.string(forType: .string) == "mine")
	}

	@Test func closingTheSheetOnTheWordsTakesThemOffThePasteboard() async throws {
		let pasteboard = NSPasteboard(name: .init("dev.hloth.nativenote.tests.\(UUID().uuidString)"))
		defer { pasteboard.releaseGlobally() }
		let calls = Calls()
		let offscreen = offscreen(.rotate, calls, clipboard: RecoveryClipboard(pasteboard))
		await offscreen.pump { onWords(offscreen) }
		try press("Copy Words", in: offscreen)

		try press("Cancel", in: offscreen)
		offscreen.close()
		await offscreen.pump { pasteboard.string(forType: .string) == nil }

		#expect(pasteboard.string(forType: .string) == nil)
	}

	@Test func aRefusedServerStaysOpenWithItsMessageAndCancelForgetsTheSession() async throws {
		let calls = Calls()
		let offscreen = offscreen(.setUp, calls, prepare: .failure(.refused))
		defer { offscreen.close() }

		try type("http://notes.example", into: try #require(fields(offscreen).first { !($0 is NSSecureTextField) }), of: offscreen)
		let key = try #require(offscreen.views(of: NSSecureTextField.self).first)
		try type("00", into: key, of: offscreen)
		key.currentEditor()?.insertNewline(nil)
		await offscreen.pump { texts(offscreen).contains(AppModel.SyncSetupFailure.refused.message) }
		#expect(calls.done == 0)

		try press("Cancel", in: offscreen)
		#expect((calls.cancelled, calls.done) == (1, 1))
	}

	@Test func aServerThatHoldsALibraryTakesAPastedPhraseIntoEveryFieldAndJoins() async throws {
		try #require(realWords.count == 24)
		let calls = Calls()
		let offscreen = offscreen(.setUp, calls, prepare: .success(.existingLibrary))
		defer { offscreen.close() }
		let words = try await reachJoin(offscreen)
		#expect(!isEnabled("Turn On Sync", in: offscreen))

		try type(realWords.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"), into: words[0], of: offscreen)
		await offscreen.pump { wordFields(offscreen).map(\.stringValue) == realWords }

		#expect(wordFields(offscreen).map(\.stringValue) == realWords)
		#expect(editing(offscreen) === wordFields(offscreen).last)
		#expect(isEnabled("Turn On Sync", in: offscreen))
		try press("Turn On Sync", in: offscreen)
		await offscreen.pump { calls.done > 0 }
		#expect(calls.joined == [["http://notes.example", "0a"] + realWords])
		#expect(calls.finished.isEmpty)
	}

	@Test func aSpaceCompletesTheWordAndMovesOnAndAWordOffTheListTurnsRedAtOnce() async throws {
		let calls = Calls()
		let offscreen = offscreen(.setUp, calls, prepare: .success(.existingLibrary))
		defer { offscreen.close() }
		let words = try await reachJoin(offscreen)

		try typeKeys("aba ", into: words[0], of: offscreen)
		await offscreen.pump { editing(offscreen) === wordFields(offscreen)[1] }
		#expect(editing(offscreen) === wordFields(offscreen)[1])
		#expect(wordFields(offscreen)[0].stringValue == "abandon")

		try typeKeys("bitcoin ", into: wordFields(offscreen)[1], of: offscreen)
		await offscreen.pump { editing(offscreen) === wordFields(offscreen)[2] }
		#expect(isRed(wordFields(offscreen)[1]))
		#expect(calls.announced == ["Word 2 is not in the recovery word list."])
		#expect(!texts(offscreen).contains { $0.contains("recovery word list") })
		#expect(!isEnabled("Turn On Sync", in: offscreen))
	}

	@Test func leavingAWordCompletesItAndReturnMovesOnFlaggingAPrefixLeftBehind() async throws {
		let calls = Calls()
		let offscreen = offscreen(.setUp, calls, prepare: .success(.existingLibrary))
		defer { offscreen.close() }
		let words = try await reachJoin(offscreen)
		#expect(editing(offscreen) === words[0])

		try typeKeys("zon", into: words[0], of: offscreen)
		#expect(!isRed(wordFields(offscreen)[0]))
		try typeKeys("zo", into: words[1], of: offscreen)
		await offscreen.pump { wordFields(offscreen)[0].stringValue == "zone" }

		#expect(wordFields(offscreen)[0].stringValue == "zone")
		#expect(!isRed(wordFields(offscreen)[1]))
		try #require(wordFields(offscreen)[1].currentEditor()).insertNewline(nil)
		await offscreen.pump { editing(offscreen) === wordFields(offscreen)[2] }
		#expect(editing(offscreen) === wordFields(offscreen)[2])
		#expect(isRed(wordFields(offscreen)[1]))
		#expect(!isRed(wordFields(offscreen)[0]) && !isRed(wordFields(offscreen)[2]))
		#expect(calls.announced == ["Word 2 is not in the recovery word list."])
	}

	@Test func aWordLeftWithASpaceShowsItsWordAndCanBeFinishedLaterWithoutTouchingTheNext() async throws {
		let calls = Calls()
		let offscreen = offscreen(.setUp, calls, prepare: .success(.existingLibrary))
		defer { offscreen.close() }
		let words = try await reachJoin(offscreen)

		try typeKeys("ab ", into: words[0], of: offscreen)
		await offscreen.pump { editing(offscreen) === wordFields(offscreen)[1] }
		#expect(wordFields(offscreen)[0].stringValue == "ab")
		try typeKeys("zoo", into: wordFields(offscreen)[1], of: offscreen)
		try typeKeys("sent", into: wordFields(offscreen)[0], of: offscreen)

		#expect(wordFields(offscreen)[0].stringValue == "absent")
		#expect(wordFields(offscreen)[1].stringValue == "zoo")
		#expect(editing(offscreen) === wordFields(offscreen)[0])
	}

	@Test func theTwentyFourFieldsRunDownEachColumnAndTabFollowsThem() async throws {
		let offscreen = offscreen(.setUp, Calls(), prepare: .success(.existingLibrary))
		defer { offscreen.close() }
		let words = try await reachJoin(offscreen)

		#expect(offscreen.onScreen(words[1]).maxY < offscreen.onScreen(words[0]).minY)
		#expect(abs(offscreen.onScreen(words[1]).minX - offscreen.onScreen(words[0]).minX) < 1)
		#expect(offscreen.onScreen(words[8]).minX > offscreen.onScreen(words[7]).maxX)

		for (key, characters, from, to): (UInt16, String, Int, Int) in [(48, "\t", 0, 1), (48, "\t", 7, 8), (48, "\u{19}", 8, 7)] {
			try #require(offscreen.window.makeFirstResponder(wordFields(offscreen)[from]))
			try sendKey(key, characters, shift: characters != "\t", to: offscreen)
			await offscreen.pump { editing(offscreen) === wordFields(offscreen)[to] }
			#expect(editing(offscreen) === wordFields(offscreen)[to], "\(from) → \(to)")
		}
	}

	private func sendKey(_ code: UInt16, _ characters: String, shift: Bool, to offscreen: OffscreenWindow<SyncSetupView>) throws {
		for type in [NSEvent.EventType.keyDown, .keyUp] {
			let event = try #require(NSEvent.keyEvent(
				with: type, location: .zero, modifierFlags: shift ? .shift : [], timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: offscreen.window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
			))
			offscreen.window.sendEvent(event)
			offscreen.pump()
		}
	}

	@Test func aNumberedListPastedInAnyOrderPutsEachWordInItsOwnField() async throws {
		try #require(realWords.count == 24)
		let offscreen = offscreen(.setUp, Calls(), prepare: .success(.existingLibrary))
		defer { offscreen.close() }
		let words = try await reachJoin(offscreen)
		let reversed = numberedList.split(separator: "\n").reversed().joined(separator: "\n")

		try type(reversed, into: words[0], of: offscreen)
		await offscreen.pump { wordFields(offscreen).map(\.stringValue) == realWords }

		#expect(wordFields(offscreen).map(\.stringValue) == realWords)
		#expect(isEnabled("Turn On Sync", in: offscreen))
	}

	@Test func aSpaceInTheLastWordStaysThereAndReturnTidiesIt() async throws {
		let calls = Calls()
		let offscreen = offscreen(.setUp, calls, prepare: .success(.existingLibrary))
		defer { offscreen.close() }
		_ = try await reachJoin(offscreen)
		let last = try #require(wordFields(offscreen).last)

		try typeKeys("zoo ", into: last, of: offscreen)
		#expect(editing(offscreen) === wordFields(offscreen).last)
		try #require(wordFields(offscreen).last?.currentEditor()).insertNewline(nil)
		await offscreen.pump { wordFields(offscreen).last?.stringValue == "zoo" }

		#expect(wordFields(offscreen).last?.stringValue == "zoo")
	}

	@Test func aPasteOverASelectedWordReplacesItAndMovesOn() async throws {
		try #require(realWords.count == 24)
		let calls = Calls()
		let offscreen = offscreen(.setUp, calls, prepare: .success(.existingLibrary))
		defer { offscreen.close() }
		let words = try await reachJoin(offscreen)
		try type(realWords.joined(separator: " "), into: words[0], of: offscreen)
		await offscreen.pump { wordFields(offscreen).map(\.stringValue) == realWords }

		try #require(offscreen.window.makeFirstResponder(wordFields(offscreen)[4]))
		try #require(wordFields(offscreen)[4].currentEditor()).selectAll(nil)
		try #require(wordFields(offscreen)[4].currentEditor()).insertText("5. Able")
		await offscreen.pump { editing(offscreen) === wordFields(offscreen)[5] && wordFields(offscreen)[4].stringValue == "able" }

		#expect(wordFields(offscreen)[4].stringValue == "able")
		#expect(wordFields(offscreen)[5].stringValue == realWords[5])
		#expect(editing(offscreen) === wordFields(offscreen)[5])
	}

	@Test func aStrayCharacterStaysInItsWordAndTheNextWordIsUntouched() async throws {
		try #require(realWords.count == 24)
		let calls = Calls()
		let offscreen = offscreen(.setUp, calls, prepare: .success(.existingLibrary))
		defer { offscreen.close() }
		let words = try await reachJoin(offscreen)
		try type(realWords.joined(separator: " "), into: words[0], of: offscreen)
		await offscreen.pump { wordFields(offscreen).map(\.stringValue) == realWords }

		try typeKeys(";x", into: wordFields(offscreen)[4], of: offscreen)

		#expect(wordFields(offscreen)[4].stringValue == realWords[4] + ";x")
		#expect(wordFields(offscreen)[5].stringValue == realWords[5])
		#expect(editing(offscreen) === wordFields(offscreen)[4])
		#expect(isRed(wordFields(offscreen)[4]))

		try typeKeys(" ", into: wordFields(offscreen)[4], of: offscreen)
		await offscreen.pump { editing(offscreen) === wordFields(offscreen)[5] }
		#expect(wordFields(offscreen)[4].stringValue == realWords[4] + ";x")
		#expect(wordFields(offscreen)[5].stringValue == realWords[5])
		#expect(editing(offscreen) === wordFields(offscreen)[5])
	}

	@Test func twentyFourListWordsThatFailTheChecksumSaySoAndCannotJoin() async throws {
		try #require(realWords.count == 24)
		let calls = Calls()
		let offscreen = offscreen(.setUp, calls, prepare: .success(.existingLibrary))
		defer { offscreen.close() }
		let words = try await reachJoin(offscreen)
		var swapped = realWords
		swapped.swapAt(3, 4)
		try #require(Mnemonic.key(from: swapped) == nil)

		try type(swapped.joined(separator: " "), into: words[0], of: offscreen)
		await offscreen.pump { texts(offscreen).contains { $0.hasPrefix("These words are not a recovery phrase.") } }

		#expect(!isEnabled("Turn On Sync", in: offscreen))
		wordFields(offscreen).last?.currentEditor()?.insertNewline(nil)
		offscreen.pump()
		#expect(calls.joined.isEmpty)
	}

	@Test func aPhraseTheServerDoesNotOpenStaysOnTheWordsWithItsMessage() async throws {
		try #require(realWords.count == 24)
		let calls = Calls()
		let offscreen = offscreen(.setUp, calls, prepare: .success(.existingLibrary), join: .phraseDoesNotOpen)
		defer { offscreen.close() }
		let words = try await reachJoin(offscreen)

		try type(realWords.joined(separator: " "), into: words[0], of: offscreen)
		wordFields(offscreen).last?.currentEditor()?.insertNewline(nil)
		await offscreen.pump { texts(offscreen).contains(AppModel.SyncSetupFailure.phraseDoesNotOpen.message) }

		#expect(calls.joined == [["http://notes.example", "0a"] + realWords])
		#expect(calls.done == 0)
		#expect(wordFields(offscreen).map(\.stringValue) == realWords)
	}

	@Test func aRotationThatFindsAnotherDeviceRotatedAdoptsTheCurrentPhraseAndStartsOver() async throws {
		let calls = Calls()
		let offscreen = offscreen(.rotate, calls, finish: .rotatedElsewhere)
		defer { offscreen.close() }
		await offscreen.pump { onWords(offscreen) }
		#expect(calls.rotations == 1)

		try press("Continue", in: offscreen)
		for (field, word) in zip(fields(offscreen), checkedWords) {
			try type(word, into: field, of: offscreen)
		}
		try press("Change Phrase", in: offscreen)
		await offscreen.pump { texts(offscreen).contains(AppModel.SyncSetupFailure.rotatedElsewhere.message) }

		#expect(!isEnabled("Continue", in: offscreen))
		try type(realWords.joined(separator: " "), into: try #require(wordFields(offscreen).first), of: offscreen)
		await offscreen.pump { isEnabled("Continue", in: offscreen) }
		try press("Continue", in: offscreen)
		await offscreen.pump { calls.rotations == 2 && onWords(offscreen) }

		#expect(calls.adopted == [realWords.joined(separator: " ")])
		#expect(calls.rotations == 2)
		#expect(calls.done == 0)
	}
}

@MainActor
struct SyncSetupFormTests {
	@Test func eachStepContinuesOnlyWithWhatItNeeds() {
		var form = SyncSetupForm(mode: .setUp)
		#expect(form.step == .server && !form.canContinue)
		form.server = "http://notes.example"
		form.apiKey = "key"
		#expect(form.canContinue)
		form.begin()
		#expect(!form.canContinue)
		form.prepared(.success(.newLibrary(phrase)))
		#expect(form.step == .words(phrase) && form.canContinue)
		form.confirm()
		#expect(form.step == .confirm(phrase) && !form.canContinue)
		form.answers = ["ab", " ", "zzzz"]
		#expect(!form.canContinue)
		form.answers = checkedWords.map { " \($0.uppercased()) " }
		#expect(form.canContinue && form.confirmTitle == "Turn On Sync")
		form.back()
		#expect(form.step == .words(phrase))
	}

	@Test func aServerWithALibraryGoesToTheWordsAndALibraryAppearingMeanwhileOrGoneRoutesThere() {
		var form = SyncSetupForm(mode: .setUp)
		form.prepared(.success(.existingLibrary))
		#expect(form.step == .join && !form.canContinue && form.continueTitle == "Turn On Sync" && form.message == nil)

		var racing = SyncSetupForm(mode: .setUp)
		racing.prepared(.success(.newLibrary(phrase)))
		racing.confirm()
		racing.begin()
		racing.finished(.serverHasLibrary)
		#expect(racing.step == .join && racing.message == AppModel.SyncSetupFailure.serverHasLibrary.message)

		racing.begin()
		racing.finished(.serverHasNoLibrary)
		#expect(racing.step == .server && racing.canContinue == false)
		racing.server = "http://notes.example"
		racing.apiKey = "key"
		#expect(racing.canContinue)
	}

	@Test func rotationStartsPreparingAndRoutesAnotherDevicesRotationToTheCurrentPhrase() {
		var form = SyncSetupForm(mode: .rotate)
		#expect(form.step == .preparing && !form.canContinue && form.confirmTitle == "Change Phrase")
		form.show(phrase)
		form.confirm()
		form.begin()
		form.finished(.rotatedElsewhere)
		#expect(form.step == .currentPhrase && form.message == AppModel.SyncSetupFailure.rotatedElsewhere.message)
		form.show(nil)
		#expect(form.message == "Sync is not set up on this Mac.")
	}
}
