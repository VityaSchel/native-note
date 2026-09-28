import Foundation
import LocalAuthenticationEmbeddedUI
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.serialized, .timeLimit(.minutes(10)))
struct LibraryEndToEndTests {
	let corpus = RealisticCorpus.bodies(count: 600)

	private struct Snapshot: Equatable {
		let body: String
		let created: Int64
		let updated: Int64
	}

	private func snapshot(_ notes: [Note]) -> [UUID: Snapshot] {
		Dictionary(uniqueKeysWithValues: notes.map {
			($0.id, Snapshot(body: $0.body, created: $0.createdAt.epochMilliseconds, updated: $0.updatedAt.epochMilliseconds))
		})
	}

	func launch(in directory: URL, password: String, keyStore: (any UnlockKeyStore)? = nil) async throws -> AppModel {
		let model = AppModel(directory: directory, keyStore: keyStore)
		model.start()
		await model.submit(password: password)
		try #require(model.phase == .unlocked, "\(String(describing: model.failure))")
		return model
	}

	func realLibrary(password: String, filled: Bool = true) async throws -> (AppModel, URL) {
		let directory = temporaryDirectory()
		let model = try await launch(in: directory, password: password)
		if filled { try await fill(model, with: corpus) }
		return (model, directory)
	}

	@Test func aRealisticLibrarySurvivesLockAndRelaunch() async throws {
		let (model, directory) = try await realLibrary(password: "correct horse battery")
		defer { try? FileManager.default.removeItem(at: directory) }
		let saved = snapshot(model.notes)
		#expect(saved.count == corpus.count)
		let parameters = try AppLock.read(from: AppLock.currentFile(in: directory))
		#expect(parameters.argon.m >= Argon2.floor.m)
		#expect((parameters.enclaveKey != nil) == MachineKey.isAvailable)

		await model.lock()
		await model.submit(password: "correct horse battery")
		#expect(snapshot(model.notes) == saved)
		await model.lock()

		let relaunched = AppModel(directory: directory)
		relaunched.start()
		#expect(relaunched.phase == .locked)
		await relaunched.submit(password: "correct horse batter")
		#expect(relaunched.failure == .wrongPassword)
		await relaunched.submit(password: "correct horse battery")
		#expect(snapshot(relaunched.notes) == saved)
	}

	@Test func anEncryptedExportRestoresTheLibraryOnAnotherSetUp() async throws {
		let (source, sourceDirectory) = try await realLibrary(password: "first machine")
		defer { try? FileManager.default.removeItem(at: sourceDirectory) }
		let saved = snapshot(source.notes)
		let file = sourceDirectory.appending(path: "Native Note.nnexport")

		#expect(await source.exportLibrary(to: file, passphrase: "export passphrase ✓"))
		#expect(AppModel.isEncryptedExport(at: file))
		let sealed = try Data(contentsOf: file)
		#expect(sealed.prefix(ExportEnvelope.header(parameters: Argon2.floor, salt: Data()).count) == ExportEnvelope.header(parameters: Argon2.floor, salt: Data()))
		#expect(sealed.range(of: Data("Trip to Lisbon".utf8)) == nil)

		let (target, targetDirectory) = try await realLibrary(password: "second machine", filled: false)
		defer { try? FileManager.default.removeItem(at: targetDirectory) }
		#expect(await target.importLibrary(from: file, passphrase: "export passphrase ✓") == ImportSummary(added: corpus.count))
		#expect(snapshot(target.notes) == saved)
		await target.lock()

		let relaunched = try await launch(in: targetDirectory, password: "second machine")
		#expect(snapshot(relaunched.notes) == saved)
	}

	@Test func aPlainExportOpensInTheSystemUnzip() async throws {
		let (model, directory) = try await realLibrary(password: "correct horse battery")
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appending(path: "Native Note.zip")
		let extracted = directory.appending(path: "extracted")

		#expect(await model.exportLibrary(to: file, passphrase: nil))
		#expect(try run("/usr/bin/unzip", ["-tq", file.path]) == 0)
		#expect(try run("/usr/bin/unzip", ["-q", file.path, "-d", extracted.path]) == 0)

		let names = try FileManager.default.contentsOfDirectory(atPath: extracted.path)
		#expect(names.count == corpus.count)
		#expect(names.allSatisfy { $0.hasSuffix(".md") })
		let read = try names.map { try NoteMarkdown.parse(String(decoding: Data(contentsOf: extracted.appending(path: $0)), as: UTF8.self)) }
		#expect(snapshot(read) == snapshot(model.notes))
	}

	@Test func editsAndDeletionsSinceAnExportComeBackAsConflictsAndTombstones() async throws {
		let (model, directory) = try await realLibrary(password: "correct horse battery")
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appending(path: "Native Note.zip")
		#expect(await model.exportLibrary(to: file, passphrase: nil))
		let exported = snapshot(model.notes)
		let ids = model.notes.map(\.id).sorted { $0.uuidString < $1.uuidString }
		let edited = Array(ids.prefix(25))
		let deleted = Array(ids.dropFirst(25).prefix(5))
		for id in edited { model.edit(id, (exported[id]?.body ?? "") + "\nedited after the export") }
		for id in deleted {
			model.selection = id
			await model.deleteSelected()
		}
		await model.flushPendingSaves()

		let summary = await model.importLibrary(from: file, passphrase: nil)

		#expect(summary == ImportSummary(unchanged: corpus.count - 30, conflicting: 25, deletedHere: 5))
		for conflict in model.conflicts.sorted(by: { $0.id.uuidString < $1.id.uuidString }).enumerated().map({ $1 }) {
			await model.resolve(conflict, edited.firstIndex(of: conflict.id)! < 12 ? .keepTheirs : .keepMine)
		}
		#expect(model.conflicts.isEmpty)
		await model.lock()

		let relaunched = try await launch(in: directory, password: "correct horse battery")
		let restored = snapshot(relaunched.notes)
		#expect(restored.count == corpus.count - 5)
		for (index, id) in edited.enumerated() {
			let expected = index < 12 ? exported[id]?.body : (exported[id]?.body ?? "") + "\nedited after the export"
			#expect(restored[id]?.body == expected)
		}
		#expect(deleted.allSatisfy { restored[$0] == nil })
	}

	@Test func changingThePasswordKeepsEveryNote() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let unlocked = try await Unlock.setUp(password: "old password", in: directory) {
			var parameters = try Unlock.makeParameters()
			parameters.argon.m = Argon2.floor.m / 2
			return parameters
		}
		for body in corpus.prefix(200) { try await unlocked.store.save(sampleNote(body: body)) }
		let saved = try await snapshot(unlocked.store.liveNotes())

		try await Unlock.changePassword(from: "old password", to: "new password ✓", parameters: unlocked.parameters, store: unlocked.store, in: directory)
		await unlocked.store.close()

		#expect(AppLock.parameterFiles(in: directory) == [AppLock.currentFile(in: directory)])
		let recalibrated = try AppLock.read(from: AppLock.currentFile(in: directory))
		#expect(recalibrated.argon.m >= Argon2.floor.m)
		#expect(recalibrated.argon.t == Argon2.floor.t)
		#expect(recalibrated.localSalt != unlocked.parameters.localSalt)
		let relaunched = try await launch(in: directory, password: "new password ✓")
		#expect(snapshot(relaunched.notes) == saved)
		await relaunched.lock()
		await relaunched.submit(password: "old password")
		#expect(relaunched.failure == .wrongPassword)
	}

	@Test func changingThePasswordFromTheAppKeepsEveryNote() async throws {
		let (model, directory) = try await realLibrary(password: "old password")
		defer { try? FileManager.default.removeItem(at: directory) }
		let edited = try #require(model.selection)
		model.edit(edited, "typed just before the change")
		let saved = snapshot(model.notes)

		#expect(await model.changePassword(from: "old password", to: "new password ✓") == nil)
		await model.lock()

		let relaunched = try await launch(in: directory, password: "new password ✓")
		#expect(snapshot(relaunched.notes) == saved)
		await relaunched.lock()
		await relaunched.submit(password: "old password")
		#expect(relaunched.failure == .wrongPassword)
	}

	@Test func touchIDTurnedOnWithThePasswordUnlocksTheRelaunchedLibrary() async throws {
		let keys = FakeKeyStore()
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let model = try await launch(in: directory, password: "correct horse battery", keyStore: keys)
		try await fill(model, with: corpus)
		let saved = snapshot(model.notes)

		#expect(await model.enableBiometricUnlock(password: "correct horse batter") == .wrongPassword)
		#expect(keys.storedKey == nil)
		try await turnOnTouchID(model, password: "correct horse battery")
		await model.lock()
		keys.reply(with: .miss)
		let missed = ContinuousClock.now
		#expect(await touch(model))
		#expect(model.touchID == .paused(.shaking))
		for _ in 0 ..< 400 where model.touchID.listeningContext == nil {
			try await Task.sleep(for: .milliseconds(5))
		}
		#expect(ContinuousClock.now - missed >= AppModel.Shake.duration)
		#expect(model.shake == AppModel.Shake(count: 1, isRunning: false))
		keys.reply(with: .key)
		#expect(await touch(model))
		#expect(model.phase == .unlocked)
		#expect(snapshot(model.notes) == saved)
		await model.close()

		let relaunched = AppModel(directory: directory, keyStore: keys)
		relaunched.start()
		#expect(relaunched.touchID == .paused(.inBackground))
		relaunched.appBecameActive()
		let glyph = PairedGlyph(try #require(relaunched.touchID.listeningContext))
		await relaunched.listen(through: glyph.view)

		#expect(relaunched.phase == .unlocked)
		#expect(relaunched.failure == nil)
		#expect(snapshot(relaunched.notes) == saved)
		#expect(keys.reasons == ["turn on Touch ID unlock", "unlock your notes", "unlock your notes", "unlock your notes"])
		#expect(keys.contexts.last === glyph.view.context)
		#expect(keys.contexts.allSatisfy(isInvalidated))
	}

	@Test func setUpAfterACrashKeepsTheOrphanedNotes() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let orphan = try await openStore(at: AppLock.databaseFile(in: directory))
		for body in corpus.prefix(100) { try await orphan.save(sampleNote(body: body)) }
		let orphaned = try await snapshot(orphan.liveNotes())
		await orphan.close()

		let model = try await launch(in: directory, password: "fresh start")

		#expect(model.notes.isEmpty)
		let aside = try #require(try FileManager.default.contentsOfDirectory(atPath: directory.path).first { $0.hasPrefix("notes-set-aside-") && $0.hasSuffix(".db") })
		let kept = try await NoteStore.open(url: directory.appending(path: aside), key: databaseKey)
		#expect(try await snapshot(kept.liveNotes()) == orphaned)
	}

	@Test func erasingARealLibraryLeavesNothingToOpen() async throws {
		let (model, directory) = try await realLibrary(password: "forgotten password")
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.lock()

		await model.eraseLibrary()

		#expect(model.phase == .needsSetup)
		#expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
		let relaunched = AppModel(directory: directory)
		relaunched.start()
		#expect(relaunched.phase == .needsSetup)
		await relaunched.submit(password: "a new start")
		#expect(relaunched.phase == .unlocked)
		#expect(relaunched.notes.isEmpty)
	}

	private func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: tool)
		process.arguments = arguments
		process.standardOutput = FileHandle.nullDevice
		process.standardError = FileHandle.nullDevice
		try process.run()
		process.waitUntilExit()
		return process.terminationStatus
	}
}
