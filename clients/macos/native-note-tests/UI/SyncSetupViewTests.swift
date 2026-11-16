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
private let phrase = AppModel.RecoveryPhrase(words: realWords, positionsToConfirm: [2, 10, 19])
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
				return .success(phrase)
			},
			finishRotation: { answers in
				calls.finished.append(answers)
				return finish
			},
			adoptCurrentPhrase: { entry in
				calls.adopted.append(entry.words.joined(separator: " "))
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
		try offscreen.type("http://notes.example", into: try #require(fields(offscreen).first { !($0 is NSSecureTextField) }))
		let key = try #require(offscreen.views(of: NSSecureTextField.self).first)
		try offscreen.type("0a", into: key)
		key.currentEditor()?.insertNewline(nil)
		await offscreen.pump { offscreen.texts().contains("Enter Your Recovery Phrase") && wordFields(offscreen).count == 24 }
		await offscreen.pump { editing(offscreen) === wordFields(offscreen).first }
		return wordFields(offscreen)
	}

	private func onWords(_ offscreen: OffscreenWindow<SyncSetupView>) -> Bool {
		offscreen.texts().contains("Write Down Your Recovery Phrase")
	}

	private func unknownWordMarks(in offscreen: OffscreenWindow<SyncSetupView>) -> Int {
		offscreen.accessibilityElements(.image).count { $0.label == PhraseFields.unknownWordLabel }
	}

	private func isEnabled(_ label: String, in offscreen: OffscreenWindow<SyncSetupView>) -> Bool {
		offscreen.accessibilityElements(.button).first { $0.label == label }?.isEnabled == true
	}

	private func fields(_ offscreen: OffscreenWindow<SyncSetupView>) -> [NSTextField] {
		offscreen.views(of: NSTextField.self).filter(\.isEditable).sorted { offscreen.onScreen($0).maxY > offscreen.onScreen($1).maxY }
	}

	@Test func theServerStepNamesOnlyItsFields() {
		let offscreen = offscreen(.setUp, Calls())
		defer { offscreen.close() }
		offscreen.pump()

		#expect(!offscreen.texts().contains { $0.contains("api-key file") })
	}

	@Test func setupTakesTheServerShowsTheWordsAndChecksThreeBeforeTurningSyncOn() async throws {
		let calls = Calls()
		let offscreen = offscreen(.setUp, calls)
		defer { offscreen.close() }

		let server = try #require(fields(offscreen).first { !($0 is NSSecureTextField) })
		let key = try #require(offscreen.views(of: NSSecureTextField.self).first)
		try offscreen.type("http://notes.example:8080", into: server)
		try offscreen.type("0a0b", into: key)
		key.currentEditor()?.insertNewline(nil)
		await offscreen.pump { onWords(offscreen) }
		#expect(calls.prepared == [["http://notes.example:8080", "0a0b"]])
		#expect(!offscreen.texts().contains { $0.contains(realWords[23]) })

		try offscreen.press("Continue")
		let answers = fields(offscreen)
		#expect(answers.count == 3)
		for (field, word) in zip(answers, checkedWords) {
			try offscreen.type(word, into: field)
		}
		try offscreen.press("Turn On Sync")
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

		try offscreen.press("Copy Words")
		#expect(pasteboard.string(forType: .string) == numberedList)
		#expect(Set(pasteboard.types ?? []).isSuperset(of: [RecoveryClipboard.concealed, RecoveryClipboard.transient]))
		offscreen.pump(for: 0.1)
		#expect(!offscreen.texts().contains { $0.hasPrefix("Copied") })
		try offscreen.press("Continue")
		for (field, word) in zip(fields(offscreen), checkedWords) {
			try offscreen.type(word, into: field)
		}
		try offscreen.press("Change Phrase")
		await offscreen.pump { calls.done > 0 }
		offscreen.close()

		#expect(calls.done == 1)
		#expect(pasteboard.string(forType: .string) == numberedList)
	}

	@Test func changingToAServerThatHoldsThisLibraryClosesWithoutWords() async throws {
		let calls = Calls()
		let offscreen = offscreen(.changeServer, calls, prepare: .success(.reattached), server: "http://old.example:8080")
		defer { offscreen.close() }
		#expect(offscreen.texts().contains("Change Server"))
		#expect(offscreen.texts().contains { $0.contains("its API key, also after the server moved or its key was replaced") })
		let address = try #require(fields(offscreen).first { !($0 is NSSecureTextField) })
		#expect(address.stringValue == "http://old.example:8080")

		let key = try #require(offscreen.views(of: NSSecureTextField.self).first)
		try offscreen.type("0a0b", into: key)
		try offscreen.press("Continue")
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
		try offscreen.type("0a0b", into: key)
		try offscreen.press("Continue")
		await offscreen.pump { onWords(offscreen) }
		try offscreen.press("Continue")
		for (field, word) in zip(fields(offscreen), checkedWords) {
			try offscreen.type(word, into: field)
		}

		try offscreen.press("Move Library")
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
		try offscreen.press("Continue")
		let answers = fields(offscreen)
		for (field, word) in zip(answers, checkedWords) {
			try offscreen.type(word, into: field)
		}
		#expect(isEnabled("Change Phrase", in: offscreen))

		try offscreen.type("ab", into: answers[0])
		#expect(!isRed(answers[0]))
		#expect(unknownWordMarks(in: offscreen) == 0)
		#expect(!isEnabled("Change Phrase", in: offscreen))
		try offscreen.type("zzzz", into: answers[0])
		await offscreen.pump { isRed(answers[0]) }

		#expect(isRed(answers[0]))
		#expect(unknownWordMarks(in: offscreen) == 1)
		#expect(!isEnabled("Change Phrase", in: offscreen))
		#expect(!offscreen.texts().contains { $0.contains("recovery word list") })
		#expect(calls.announced == ["Word 3 is not in the recovery word list."])
		answers[0].currentEditor()?.insertNewline(nil)
		offscreen.pump()
		#expect(calls.finished.isEmpty)
	}

	@Test func theWordsStayBlurredBehindAWarningUntilRevealedThenReadDownEachColumn() async throws {
		let offscreen = offscreen(.rotate, Calls())
		defer { offscreen.close() }
		await offscreen.pump { onWords(offscreen) }

		#expect(offscreen.texts().contains(RecoveryWords.warning))
		#expect(offscreen.texts().contains("These words are used to encrypt your notes on your sync server. Keep them safe and never share with anyone."))
		#expect(!offscreen.texts().contains { text in realWords.contains { text.contains($0) } })
		#expect(!offscreen.texts().contains { $0.contains(RecoveryWords.hiddenWord) })
		#expect(offscreen.button("Copy Words") != nil)

		try offscreen.press("Reveal")
		await offscreen.pump { offscreen.button("Reveal") == nil }

		#expect((0 ..< RecoveryWords.columns).map { RecoveryWords.positions(inColumn: $0, of: realWords.count) } == [0 ..< 8, 8 ..< 16, 16 ..< 24])
		#expect(offscreen.texts().contains(numberedList))
		#expect(!offscreen.texts().contains(RecoveryWords.warning))
		#expect(offscreen.button("Reveal") == nil)
	}

	@Test func eachDrawnWordSitsBesideItsOwnNumberReadingDownEachColumn() throws {
		let offscreen = OffscreenWindow(RecoveryColumns(words: realWords), width: 440, height: 260)
		defer { offscreen.close() }
		let drawn = offscreen.accessibilityElements(.staticText).map { (text: $0.value.isEmpty ? $0.label : $0.value, frame: $0.frame) }
		let numbers = drawn.filter { $0.text.hasSuffix(".") }
		let words = drawn.filter { !$0.text.hasSuffix(".") }
		try #require(numbers.count == realWords.count && words.count == realWords.count)

		let rows = try numbers.map { number in
			let beside = words.filter { abs($0.frame.midY - number.frame.midY) < number.frame.height / 2 && $0.frame.minX >= number.frame.maxX - 1 }
			return (number: number.text, word: try #require(beside.min { $0.frame.minX < $1.frame.minX }))
		}
		let reading = rows.sorted {
			abs($0.word.frame.minX - $1.word.frame.minX) > 1 ? $0.word.frame.minX < $1.word.frame.minX : $0.word.frame.maxY > $1.word.frame.maxY
		}

		#expect(reading.map { "\($0.number) \($0.word.text)" }.joined(separator: "\n") == numberedList)
		#expect(Set(reading.map { $0.word.frame.minX.rounded() }).count == RecoveryWords.columns)
		#expect(reading[RecoveryWords.rows].word.frame.minX > reading[0].word.frame.maxX)
		#expect(reading[RecoveryWords.rows].word.frame.midY == reading[0].word.frame.midY)
	}

	@Test func theRevealedWordsCannotBeSelectedSoCopyWordsIsTheOnlyWayToThePasteboard() async throws {
		let pasteboard = NSPasteboard(name: .init("dev.hloth.nativenote.tests.\(UUID().uuidString)"))
		defer { pasteboard.releaseGlobally() }
		let offscreen = offscreen(.rotate, Calls(), clipboard: RecoveryClipboard(pasteboard))
		defer { offscreen.close() }
		await offscreen.pump { onWords(offscreen) }
		try offscreen.press("Reveal")
		await offscreen.pump { offscreen.texts().contains(numberedList) }
		try #require(offscreen.texts().contains(numberedList))

		#expect(offscreen.views(of: NSTextView.self).isEmpty)
		#expect(offscreen.views(of: NSTextField.self).allSatisfy { !$0.isSelectable })
		#expect(offscreen.window.firstResponder?.responds(to: #selector(NSText.copy(_:))) != true)
		#expect(offscreen.host.validRequestor(forSendType: .string, returnType: nil) == nil)
		#expect(pasteboard.string(forType: .string) == nil)

		try offscreen.press("Copy Words")
		#expect(pasteboard.string(forType: .string) == numberedList)
		#expect(Set(pasteboard.types ?? []).isSuperset(of: [RecoveryClipboard.concealed, RecoveryClipboard.transient]))
	}

	@Test func cancelSitsAtTheLeadingEdgeApartFromBackAndTheNextStep() async throws {
		let offscreen = offscreen(.rotate, Calls())
		defer { offscreen.close() }
		await offscreen.pump { onWords(offscreen) }
		let words = try #require(offscreen.button("Cancel")).frame
		let next = try #require(offscreen.button("Continue")).frame
		#expect(next.minX - words.maxX > 200)

		try offscreen.press("Continue")
		await offscreen.pump { offscreen.button("Back") != nil }
		let cancel = try #require(offscreen.button("Cancel")).frame
		let back = try #require(offscreen.button("Back")).frame
		let change = try #require(offscreen.button("Change Phrase")).frame

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
		try offscreen.type("http://notes.example:8080", into: try #require(fields(offscreen).first { !($0 is NSSecureTextField) }))
		try offscreen.type("0a0b", into: try #require(offscreen.views(of: NSSecureTextField.self).first))
		try offscreen.press("Continue")
		await offscreen.pump { !isEnabled("Continue", in: offscreen) }
		#expect(isEnabled("Cancel", in: offscreen))

		try offscreen.press("Cancel")
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
		try offscreen.type("http://notes.example:8080", into: try #require(fields(offscreen).first { !($0 is NSSecureTextField) }))
		try offscreen.type("0a0b", into: try #require(offscreen.views(of: NSSecureTextField.self).first))
		try offscreen.press("Continue")
		await offscreen.pump { onWords(offscreen) }
		try offscreen.press("Continue")
		for (field, word) in zip(fields(offscreen), checkedWords) {
			try offscreen.type(word, into: field)
		}

		try offscreen.press("Turn On Sync")
		await offscreen.pump { !isEnabled("Cancel", in: offscreen) }

		#expect(!isEnabled("Cancel", in: offscreen))
	}

	@Test func theConfirmStepNamesTheWordsToEnter() async throws {
		let calls = Calls()
		let offscreen = offscreen(.rotate, calls)
		defer { offscreen.close() }
		await offscreen.pump { onWords(offscreen) }

		try offscreen.press("Continue")
		let numbers = [3, 11, 20].formatted(.list(memberStyle: .number, type: .and))
		await offscreen.pump { offscreen.texts().contains("Enter words \(numbers) from the phrase you wrote down.") }

		#expect(offscreen.texts().contains("Enter words \(numbers) from the phrase you wrote down."))
		#expect(["3, 11, and 20", "3, 11 and 20"].contains(numbers))
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

		try offscreen.press("Copy Words")
		pasteboard.clearContents()
		pasteboard.setString("mine", forType: .string)
		try offscreen.press("Continue")
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
		try offscreen.press("Copy Words")

		try offscreen.press("Cancel")
		offscreen.close()
		await offscreen.pump { pasteboard.string(forType: .string) == nil }

		#expect(pasteboard.string(forType: .string) == nil)
	}

	@Test func aRefusedServerStaysOpenWithItsMessageAndCancelForgetsTheSession() async throws {
		let calls = Calls()
		let offscreen = offscreen(.setUp, calls, prepare: .failure(.refused))
		defer { offscreen.close() }

		try offscreen.type("http://notes.example", into: try #require(fields(offscreen).first { !($0 is NSSecureTextField) }))
		let key = try #require(offscreen.views(of: NSSecureTextField.self).first)
		try offscreen.type("00", into: key)
		key.currentEditor()?.insertNewline(nil)
		await offscreen.pump { offscreen.texts().contains(AppModel.SyncSetupFailure.refused.message) }
		#expect(calls.done == 0)

		try offscreen.press("Cancel")
		#expect((calls.cancelled, calls.done) == (1, 1))
	}

	@Test func aServerThatHoldsALibraryTakesAPastedPhraseIntoEveryFieldAndJoins() async throws {
		try #require(realWords.count == 24)
		let calls = Calls()
		let offscreen = offscreen(.setUp, calls, prepare: .success(.existingLibrary))
		defer { offscreen.close() }
		let words = try await reachJoin(offscreen)
		#expect(!isEnabled("Turn On Sync", in: offscreen))

		try offscreen.type(realWords.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"), into: words[0])
		await offscreen.pump { wordFields(offscreen).map(\.stringValue) == realWords }

		#expect(wordFields(offscreen).map(\.stringValue) == realWords)
		#expect(editing(offscreen) === wordFields(offscreen).last)
		#expect(isEnabled("Turn On Sync", in: offscreen))
		try offscreen.press("Turn On Sync")
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
		#expect(unknownWordMarks(in: offscreen) == 0)

		try typeKeys("bitcoin ", into: wordFields(offscreen)[1], of: offscreen)
		await offscreen.pump { editing(offscreen) === wordFields(offscreen)[2] }
		#expect(isRed(wordFields(offscreen)[1]))
		#expect(unknownWordMarks(in: offscreen) == 1)
		#expect(calls.announced == ["Word 2 is not in the recovery word list."])
		#expect(!offscreen.texts().contains { $0.contains("recovery word list") })
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

		try offscreen.type(reversed, into: words[0])
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
		try offscreen.type(realWords.joined(separator: " "), into: words[0])
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
		try offscreen.type(realWords.joined(separator: " "), into: words[0])
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

		try offscreen.type(swapped.joined(separator: " "), into: words[0])
		await offscreen.pump { offscreen.texts().contains { $0.hasPrefix("These words are not a recovery phrase.") } }

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

		try offscreen.type(realWords.joined(separator: " "), into: words[0])
		wordFields(offscreen).last?.currentEditor()?.insertNewline(nil)
		await offscreen.pump { offscreen.texts().contains(AppModel.SyncSetupFailure.phraseDoesNotOpen.message) }

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

		try offscreen.press("Reveal")
		await offscreen.pump { offscreen.button("Reveal") == nil }
		try #require(offscreen.texts().contains(numberedList))
		try offscreen.press("Continue")
		try offscreen.press("Back")
		await offscreen.pump { onWords(offscreen) }
		#expect(offscreen.texts().contains(numberedList))
		try offscreen.press("Continue")
		for (field, word) in zip(fields(offscreen), checkedWords) {
			try offscreen.type(word, into: field)
		}
		try offscreen.press("Change Phrase")
		await offscreen.pump { offscreen.texts().contains(AppModel.SyncSetupFailure.rotatedElsewhere.message) }

		#expect(!isEnabled("Continue", in: offscreen))
		try offscreen.type(realWords.joined(separator: " "), into: try #require(wordFields(offscreen).first))
		await offscreen.pump { isEnabled("Continue", in: offscreen) }
		try offscreen.press("Continue")
		await offscreen.pump { calls.rotations == 2 && onWords(offscreen) }

		#expect(offscreen.texts().contains(RecoveryWords.warning))
		#expect(offscreen.button("Reveal") != nil)
		#expect(!offscreen.texts().contains(numberedList))
		#expect(calls.adopted == [realWords.joined(separator: " ")])
		#expect(calls.rotations == 2)
		#expect(calls.done == 0)
	}

	@Test(.scratch) func aPhraseChangeOnAServerAddressThatCannotBeReadShowsWhyInTheSheetAlone() async throws {
		let model = try await libraryWithUnreadableServerAddress()
		model.dismissFailure()
		let reason = "The saved server address cannot be read. Enter the server again in Settings."

		let offscreen = OffscreenWindow(SyncSetupView(mode: .rotate, controls: SyncControls(model), done: {}), width: 440, height: 560)
		defer { offscreen.close() }
		await offscreen.pump { offscreen.texts().contains(reason) }

		#expect(offscreen.texts().contains(reason))
		#expect(!offscreen.texts().contains("Sync is not set up on this Mac."))
		#expect(model.failure == nil)
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
		form.rotationPrepared(.success(phrase))
		form.confirm()
		form.begin()
		form.finished(.rotatedElsewhere)
		#expect(form.step == .currentPhrase && form.message == AppModel.SyncSetupFailure.rotatedElsewhere.message)
		form.rotationPrepared(.failure(.notSetUp))
		#expect(form.message == "Sync is not set up on this Mac.")
	}

	@Test func aRotationThatCannotStartShowsItsOwnReason() {
		var form = SyncSetupForm(mode: .rotate)
		form.begin()

		form.rotationPrepared(.failure(.failed("The saved server address cannot be read. Enter the server again in Settings.")))

		#expect(form.step == .preparing && !form.working)
		#expect(form.message == "The saved server address cannot be read. Enter the server again in Settings.")
	}

	@Test func aNewPhraseIsHiddenAgainWhileGoingBackToTheSameOneStaysRevealed() {
		var form = SyncSetupForm(mode: .setUp)
		form.prepared(.success(.newLibrary(phrase)))
		#expect(!form.wordsRevealed)
		form.revealWords()
		form.confirm()
		form.back()
		#expect(form.wordsRevealed)

		form.confirm()
		form.begin()
		form.finished(.serverHasNoLibrary)
		form.prepared(.success(.newLibrary(AppModel.RecoveryPhrase(words: realWords.reversed(), positionsToConfirm: [0, 1, 2]))))

		#expect(!form.wordsRevealed)
	}
}
