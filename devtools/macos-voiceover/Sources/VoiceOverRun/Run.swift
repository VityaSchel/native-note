import AppKit
import VoiceOverRunKit

final class Run {
	let app: AppUnderTest
	let voiceOver: VoiceOver
	let serverBinary: URL
	let serverData: URL
	let say: (String) -> Void
	let log: PhraseLog
	var server: SyncServer?
	private(set) var failed = false
	private var passed = 0
	private var actionMark = 0
	private let password = "correct horse battery"
	private var recoveryWords: [String] = []
	private var emptyStops: [String] = []

	init(app: AppUnderTest, voiceOver: VoiceOver, server: URL, data: URL, say: @escaping (String) -> Void) {
		self.app = app
		self.voiceOver = voiceOver
		serverBinary = server
		serverData = data
		self.say = say
		log = PhraseLog { try voiceOver.lastPhrase() }
	}

	func explore() throws {
		try prepare()
		for move in 0..<40 {
			log.poll()
			say("\(move): \(try voiceOver.textUnderCursor())")
			try voiceOver.move(.right)
			log.listen(for: 0.6)
		}
		say("heard: \(log.phrases)")
		dumpTree()
	}



	func all() throws {
		try prepare()
		server = try SyncServer(binary: serverBinary, data: serverData, port: 18_457)
		try onboarding()
		try syncSetup()
		try notes()
		try lockAndUnlock()
		try settings()
		try export()
		try erase()
	}

	private func onboarding() throws {
		try step("Welcome reads its title, and Next moves on") {
			try reach("Welcome to Native Note")
			try press("Next")
		}
		try step("The password step puts VoiceOver in Password, named once") {
			let field = try hear("Password", "text")
			try expect(occurrences(of: "password", in: field) == 1, "the field's name is spoken twice: \(field)")
		}
		try step("A mismatched confirmation is read out on Return") {
			type(password)
			key(.tab)
			try hear("Confirm Password")
			type(password + "x")
			key(.returnKey)
			try hear("The passwords do not match")
		}
		try step("Fixing the confirmation moves VoiceOver to the next step's title") {
			type(password)
			key(.returnKey)
			let title = try hearAny(["Unlock with Touch ID?", "Sync Your Notes"], within: 30)
			if PhraseLog.normalized(title).contains("touch id") {
				try press("Skip")
				try hear("Sync Your Notes")
			}
		}
	}

	private func syncSetup() throws {
		guard let server else { throw RunError("no sync server") }
		try step("Set Up opens the sync sheet with VoiceOver in Server") {
			try press("Set Up")
			try hear("Server")
			try waitForFocus("the Server field") { $0.role == "AXTextField" }
		}
		try step("Continue reads out the recovery words step") {
			type(server.url.absoluteString)
			key(.tab)
			type(server.apiKey)
			key(.returnKey)
			try hear("Write Down Your Recovery Phrase", within: 20)
		}
		try step("Reveal moves VoiceOver to the revealed words") {
			try press("Reveal")
			try hear("1.")
			recoveryWords = try revealedWords()
			try expect(recoveryWords.count == 24, "read \(recoveryWords.count) words: \(recoveryWords)")
		}
		try step("Continue reads out the confirm step and puts VoiceOver in the first word") {
			try press("Continue")
			try hear("Confirm Your Recovery Phrase")
			try hear("Word", "text")
		}
		try step("Turning on sync opens the library with VoiceOver in the note list") {
			let fields = Element.all(in: try pid()).filter { $0.role == "AXTextField" && $0.name.hasPrefix("Word ") }
			try expect(fields.count == 3, "found \(fields.map(\.name)) to confirm")
			for (index, field) in fields.enumerated() {
				let number = Int(field.name.dropFirst("Word ".count)) ?? 0
				try expect((1...24).contains(number), "unexpected field \(field.name)")
				type(recoveryWords[number - 1])
				if index < fields.count - 1 { key(.tab) }
			}
			key(.returnKey)
			try hearAny(["No Notes", "table", "outline", "list"], within: 30)
			try waitForFocus("the note list", within: 10) { ["AXTable", "AXOutline", "AXList"].contains($0.role) }
			_ = try? waitFor("the sync sheet to close", within: 10) { Element.all(in: try self.pid()).contains { $0.role == "AXSheet" } ? nil : Element.focused(in: try self.pid()) }
			log.listen(for: 2)
		}
	}

	private func notes() throws {
		try step("New Note puts VoiceOver in the editor named Note") {
			key(.n, .maskCommand)
			try waitForFocus("the editor named Note") { $0.role == "AXTextArea" && $0.name == "Note" }
			try hear("Note", "text")
			type("Shopping\nbread and milk")
			log.listen(for: 1)
		}
		try step("VoiceOver reaches the spoken date line before the note") {
			let year = String(Calendar.current.component(.year, from: .now))
			var read: [String] = []
			for move in [VoiceOver.Direction.left, .outOf, .into, .right, .left] {
				let text = try voiceOver.textUnderCursor()
				read.append(text)
				if text.contains(year) { return }
				try voiceOver.move(move)
				log.listen(for: 0.4)
			}
			throw RunError("VoiceOver never read the date line; from the editor it read \(read)")
		}
		try step("Sync Now reads out its outcome") {
			key(.r, .maskCommand)
			try hear("Last synced", within: 20)
		}
	}

	private func lockAndUnlock() throws {
		try step("Lock puts VoiceOver in the password field") {
			key(.l, .maskCommand)
			try hear("Password", "text", within: 15)
		}
		try step("A wrong password is read out") {
			type("wrong password")
			key(.returnKey)
			try hear("Wrong password", within: 30)
		}
		try step("The right password opens the library again") {
			log.listen(for: 1)
			type(password)
			key(.returnKey)
			try hearAny(["Shopping", "table", "outline", "list"], within: 30)
			_ = try waitFor("the library with its note", within: 10) { Element.all(in: try self.pid()).first { $0.role == "AXWindow" && $0.name.contains("1 note") } }
		}
	}

	private func settings() throws {
		try step("Settings opens and Change Password reads out a wrong current password") {
			key(.comma, .maskCommand)
			log.listen(for: 2)
			try press("Change Password")
			try hear("Current Password")
			type("not it")
			key(.tab)
			type("another horse")
			key(.tab)
			type("another horse")
			key(.returnKey)
			try hear("Wrong current password", within: 30)
		}
		try step("Escape closes the Change Password sheet") {
			key(.escape)
			log.listen(for: 1)
			try expect(!Element.all(in: try pid()).contains { $0.role == "AXSecureTextField" && $0.name.contains("Current Password") }, "the sheet is still open")
		}
		try step("Turn Off Sync asks first, and Escape keeps sync on") {
			try press("Turn Off Sync")
			try hear("Turn Off Sync")
			key(.escape)
			log.listen(for: 1)
			try expect(Element.all(in: try pid()).contains { $0.role == "AXButton" && $0.name.hasPrefix("Change Recovery Phrase") }, "sync turned off")
		}
		key(.w, .maskCommand)
		log.listen(for: 1)
	}

	private func export() throws {
		try step("Export reads out mismatched passphrases") {
			guard let item = Element.menuItem("Export…", in: try pid()) else { throw RunError("no Export… menu item") }
			actionMark = log.mark
			item.press()
			try hear("Passphrase")
			try waitForFocus("the Passphrase field") { $0.role == "AXTextField" }
			type("export phrase")
			key(.tab)
			actionMark = log.mark
			type("export phrasf")
			try hear("The passphrases do not match")
			key(.escape)
			log.listen(for: 1)
		}
	}

	private func erase() throws {
		try step("Forgot Password erases the notes and onboarding reads its title again") {
			if Element.all(in: try pid()).contains(where: { $0.role == "AXSheet" }) {
				key(.escape)
				log.listen(for: 1)
			}
			key(.l, .maskCommand)
			log.listen(for: 2)
			try press("Forgot Password?")
			try hear("Erase all notes")
			try press("Erase Notes")
			try hear("Welcome to Native Note", within: 20)
		}
	}

	private func step(_ name: String, _ body: () throws -> Void) throws {
		do {
			try body()
			passed += 1
			say("PASS \(name)")
		} catch {
			failed = true
			say("FAIL \(name)\n  \(error)\n  heard: \(log.heard(since: max(0, actionMark - 3)))")
			if let pid = app.pid, let focus = Element.focused(in: pid) { say("  focus: \(focus.role) \(focus.name)") }
			if app.pid == nil || !(app.running.map { !$0.isTerminated } ?? false) { throw error }
		}
	}

	@discardableResult
	private func hear(_ parts: String..., since mark: Int? = nil, within seconds: TimeInterval = 8) throws -> String {
		let start = mark ?? actionMark
		let deadline = Date.now.addingTimeInterval(seconds)
		while Date.now < deadline {
			log.poll()
			if let phrase = log.heard(since: start).first(where: { phrase in parts.allSatisfy { PhraseLog.normalized(phrase).contains(PhraseLog.normalized($0)) } }) {
				return phrase
			}
			Clock.pause(0.02)
		}
		throw RunError("VoiceOver never said \(parts)")
	}

	@discardableResult
	private func hearAny(_ options: [String], since start: Int? = nil, within seconds: TimeInterval) throws -> String {
		let mark = start ?? actionMark
		let deadline = Date.now.addingTimeInterval(seconds)
		while Date.now < deadline {
			log.poll()
			for option in options {
				if let phrase = log.firstHeard(option, since: mark) { return phrase }
			}
			Clock.pause(0.02)
		}
		throw RunError("VoiceOver said none of \(options)")
	}

	private func reach(_ name: String, directions: [VoiceOver.Direction] = [.right, .left], moves: Int = 40) throws {
		try reach(directions: directions, moves: moves, describing: name) { PhraseLog.normalized($0).contains(PhraseLog.normalized(name)) }
	}

	private func reachControl(_ name: String) throws {
		let controls = ["button", "link", "checkbox", "switch", "pop up button", "menu button"]
		try reach(directions: [.right, .left], moves: 40, describing: name) { text in
			let spoken = PhraseLog.normalized(text)
			return spoken.contains(PhraseLog.normalized(name)) && controls.contains { spoken.hasSuffix($0) }
		}
	}

	private func reach(directions: [VoiceOver.Direction], moves: Int, describing name: String, _ matches: (String) -> Bool) throws {
		var read: [String] = []
		for direction in directions {
			var previous = ""
			var repeats = 0
			for _ in 0..<moves {
				log.poll()
				let text = try voiceOver.textUnderCursor()
				if matches(text) { return }
				read.append(text)
				if text.isEmpty, !previous.isEmpty, !emptyStops.contains(previous) {
					emptyStops.append(previous)
					say("  NOTE VoiceOver stopped on an empty item after \"\(previous)\"")
				}
				repeats = text == previous ? repeats + 1 : 0
				if repeats >= 2 { break }
				previous = text
				try voiceOver.move(direction)
				log.listen(for: 0.25)
			}
		}
		throw RunError("VoiceOver never reached \"\(name)\"; it read \(read)")
	}

	private func press(_ name: String) throws {
		try reachControl(name)
		actionMark = log.mark
		try voiceOver.performAction()
		log.listen(for: 0.5)
	}

	private func type(_ text: String) {
		if !app.isFrontmost { app.activate() }
		_ = try? waitForFocus("a text field") { ["AXTextField", "AXTextArea"].contains($0.role) }
		log.listen(for: 0.5)
		let pasteboard = NSPasteboard.general
		let saved = pasteboard.pasteboardItems?.map { item in
			item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
		} ?? []
		pasteboard.clearContents()
		pasteboard.setString(text, forType: .string)
		Keyboard.press(.v, .maskCommand)
		log.listen(for: 0.8)
		pasteboard.clearContents()
		pasteboard.writeObjects(saved.map { contents in
			let item = NSPasteboardItem()
			for (type, data) in contents { item.setData(data, forType: type) }
			return item
		})
	}

	private func key(_ key: Keyboard.Key, _ flags: CGEventFlags = []) {
		if !app.isFrontmost { app.activate() }
		log.poll()
		actionMark = log.mark
		Keyboard.press(key, flags)
	}

	private func revealedWords() throws -> [String] {
		guard let list = Element.all(in: try pid()).first(where: { $0.value.hasPrefix("1. ") }) else { throw RunError("no revealed word list") }
		return list.value.split(separator: "\n").compactMap { line in line.split(separator: " ").last.map(String.init) }
	}

	private func occurrences(of word: String, in phrase: String) -> Int {
		PhraseLog.normalized(phrase).components(separatedBy: word).count - 1
	}

	private func expect(_ condition: Bool, _ message: String) throws {
		if !condition { throw RunError(message) }
	}

	private func pid() throws -> pid_t {
		guard let pid = app.pid else { throw RunError("the app is not running") }
		return pid
	}

	private func dumpTree() {
		guard let pid = app.pid else { return }
		for element in Element.all(in: pid) where !element.name.isEmpty || !element.value.isEmpty {
			say("  AX \(element.role) name=\(element.name) value=\(element.value.prefix(60).replacing("\n", with: " "))\(element.isFocused ? " FOCUSED" : "")")
		}
	}

	func prepare() throws {
		app.quit()
		try voiceOver.start()
		try app.launch()
		log.listen(for: 3)
		if let forgot = button("Forgot Password?") {
			forgot.press()
			try waitFor("the Erase Notes alert") { self.button("Erase Notes") }.press()
			_ = try waitFor("onboarding") { Element.all(in: try self.pid()).first { $0.role == "AXHeading" && $0.name == "Welcome to Native Note" } }
			log.listen(for: 2)
		}
	}

	private func button(_ name: String) -> Element? {
		app.pid.flatMap { pid in Element.all(in: pid).first { ["AXButton", "AXLink"].contains($0.role) && $0.name == name } }
	}

	private func waitForFocus(_ what: String, within seconds: TimeInterval = 5, _ matches: (Element) -> Bool) throws {
		let deadline = Date.now.addingTimeInterval(seconds)
		while Date.now < deadline {
			log.poll()
			if let pid = app.pid, let focus = Element.focused(in: pid), matches(focus) { return }
			Clock.pause(0.05)
		}
		let focus = app.pid.flatMap(Element.focused(in:))
		throw RunError("focus never reached \(what); it is on \(focus?.role ?? "nothing") \(focus?.name ?? "")")
	}

	private func waitFor(_ what: String, within seconds: TimeInterval = 15, _ find: () throws -> Element?) throws -> Element {
		let deadline = Date.now.addingTimeInterval(seconds)
		while Date.now < deadline {
			if let found = try find() { return found }
			Clock.pause(0.2)
		}
		throw RunError("\(what) never appeared")
	}

	func finish() {
		app.quit()
		server?.stop()
		voiceOver.quit()
		say(failed ? "FAILED after \(passed) passing steps" : "PASSED \(passed) steps")
	}
}
