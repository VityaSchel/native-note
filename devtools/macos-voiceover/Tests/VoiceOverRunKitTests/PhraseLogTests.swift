import Testing
import VoiceOverRunKit

struct PhraseLogTests {
	@Test func aPhraseIsRecordedOnceUntilVoiceOverSaysSomethingElse() {
		let log = PhraseLog { "" }
		for phrase in ["Password, secure text field", "Password, secure text field", " ", "Wrong password", "Password, secure text field"] {
			log.record(phrase)
		}

		#expect(log.phrases == ["Password, secure text field", "Wrong password", "Password, secure text field"])
	}

	@Test func whatWasHeardIsFoundSinceAMarkIgnoringCaseSpacingAndCurlyApostrophes() {
		let log = PhraseLog { "" }
		log.record("Touch ID didn\u{2019}t  match")
		let mark = log.mark
		log.record("Sync failed:   The server could not be reached.")

		#expect(log.firstHeard("touch id didn't match", since: mark) == nil)
		#expect(log.firstHeard("touch id didn't match", since: 0) == "Touch ID didn\u{2019}t  match")
		#expect(log.firstHeard("sync failed: the server", since: mark) != nil)
	}
}
