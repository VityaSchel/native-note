import AppKit
@testable import NativeNoteKit
import Testing

@testable import NativeNote

@MainActor
private final class Calls {
	var prepared: [[String]] = []
	var finished: [[String]] = []
	var rotations = 0
	var adopted: [String] = []
	var cancelled = 0
	var done = 0
}

private let phrase = AppModel.RecoveryPhrase(words: (1 ... 24).map { "word\($0)" }, checked: [2, 10, 19])

@MainActor
struct SyncSetupViewTests {
	private func offscreen(
		_ mode: SyncSetupForm.Mode,
		_ calls: Calls,
		prepare: Result<AppModel.RecoveryPhrase, AppModel.SyncSetupFailure> = .success(phrase),
		finish: AppModel.SyncSetupFailure? = nil,
		adopt: AppModel.SyncSetupFailure? = nil
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
		return OffscreenWindow(SyncSetupView(mode: mode, controls: controls, done: { calls.done += 1 }), width: 440, height: 520)
	}

	private func fields(_ offscreen: OffscreenWindow<SyncSetupView>) -> [NSTextField] {
		offscreen.views(of: NSTextField.self).filter(\.isEditable).sorted { offscreen.onScreen($0).maxY > offscreen.onScreen($1).maxY }
	}

	private func type(_ text: String, into field: NSTextField, of offscreen: OffscreenWindow<SyncSetupView>) throws {
		try #require(offscreen.window.makeFirstResponder(field))
		try #require(field.currentEditor()).insertText(text)
		offscreen.pump()
	}

	private func texts(_ offscreen: OffscreenWindow<SyncSetupView>) -> [String] {
		offscreen.accessibilityElements(.staticText).map(\.value)
	}

	private func press(_ label: String, in offscreen: OffscreenWindow<SyncSetupView>) throws {
		try #require(offscreen.accessibilityElements(.button).first { $0.label == label }).press()
		offscreen.pump()
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
		await offscreen.pump { texts(offscreen).contains("1. word1") }
		#expect(calls.prepared == [["http://notes.example:8080", "0a0b"]])
		#expect(texts(offscreen).contains("24. word24"))

		try press("Continue", in: offscreen)
		let answers = fields(offscreen)
		#expect(answers.count == 3)
		for (field, word) in zip(answers, ["word3", "word11", "word20"]) {
			try type(word, into: field, of: offscreen)
		}
		try press("Turn On Sync", in: offscreen)
		await offscreen.pump { calls.done > 0 }

		#expect(calls.finished == [["word3", "word11", "word20"]])
		#expect(calls.cancelled == 0)
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

	@Test func aRotationThatFindsAnotherDeviceRotatedAdoptsTheCurrentPhraseAndStartsOver() async throws {
		let calls = Calls()
		let offscreen = offscreen(.rotate, calls, finish: .rotatedElsewhere)
		defer { offscreen.close() }
		await offscreen.pump { texts(offscreen).contains("1. word1") }
		#expect(calls.rotations == 1)

		try press("Continue", in: offscreen)
		for (field, word) in zip(fields(offscreen), ["word3", "word11", "word20"]) {
			try type(word, into: field, of: offscreen)
		}
		try press("Change Phrase", in: offscreen)
		await offscreen.pump { texts(offscreen).contains(AppModel.SyncSetupFailure.rotatedElsewhere.message) }

		try type("the current words", into: try #require(fields(offscreen).first), of: offscreen)
		try press("Continue", in: offscreen)
		await offscreen.pump { calls.rotations == 2 && texts(offscreen).contains("1. word1") }

		#expect(calls.adopted == ["the current words"])
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
		form.prepared(.success(phrase))
		#expect(form.step == .words(phrase) && form.canContinue)
		form.confirm()
		#expect(form.step == .confirm(phrase) && !form.canContinue)
		form.answers = ["a", "b", "c"]
		#expect(form.canContinue && form.confirmTitle == "Turn On Sync")
		form.back()
		#expect(form.step == .words(phrase))
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
