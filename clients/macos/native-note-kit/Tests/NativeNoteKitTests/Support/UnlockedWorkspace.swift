import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

let workspacePassword = "correct horse"

@MainActor
struct Workspace {
	typealias Make = @MainActor (URL, any UnlockKeyStore) -> AppModel

	private let bodies: [String]
	private let make: Make

	init(holding bodies: [String] = [], _ make: @escaping Make) {
		self.bodies = bodies
		self.make = make
	}

	init(holding bodies: [String] = [], alarm: Alarm) {
		self.init(holding: bodies) { .testing(in: $0, scheduler: alarm.scheduler, keyStore: $1) }
	}

	func unlocked(_ keys: any UnlockKeyStore = FakeKeyStore(), holding bodies: [String]? = nil) async throws -> (AppModel, URL) {
		let directory = temporaryDirectory()
		try AppLock.write(.fast, to: AppLock.currentFile(in: directory))
		try await NoteStore.create(url: AppLock.databaseFile(in: directory), key: workspaceKey()).close()
		let model = make(directory, keys)
		model.start()
		await model.unlock(password: workspacePassword)
		try #require(model.phase == .unlocked)
		let bodies = bodies ?? self.bodies
		if !bodies.isEmpty { try await fill(model, with: bodies) }
		return (model, directory)
	}

	func unlockedWithTouchID(_ keys: FakeKeyStore) async throws -> (AppModel, URL) {
		let (model, directory) = try await unlocked(keys)
		try await turnOnTouchID(model)
		keys.forgetReads()
		return (model, directory)
	}

	func lockedWithTouchID(_ keys: FakeKeyStore) async throws -> (AppModel, URL) {
		let (model, directory) = try await unlockedWithTouchID(keys)
		await model.lock()
		return (model, directory)
	}
}

@MainActor
func unlockedModel(alarm: Alarm) async throws -> (AppModel, URL) {
	try await Workspace(alarm: alarm).unlocked()
}

@MainActor
func unlockedModel(_ make: @escaping @MainActor (URL) -> AppModel) async throws -> (AppModel, URL) {
	try await Workspace { directory, _ in make(directory) }.unlocked()
}

@MainActor
func fill(_ model: AppModel, with bodies: [String]) async throws {
	for body in bodies {
		guard body.isEmpty else {
			await model.createNote()
			model.edit(try #require(model.selection), body)
			continue
		}
		let now = Date().epochMilliseconds
		let note = Note(id: UUID(), body: "", createdAt: now, updatedAt: now, dirty: true)
		_ = try await #require(model.store).save(note)
		model.notes.insert(note, at: 0)
		model.selection = note.id
	}
	await model.flushPendingSaves()
}

@MainActor
func turnOnTouchID(_ model: AppModel, password: String = workspacePassword) async throws {
	try #require(await enableTouchID(model, password: password) == nil)
	try #require(model.isBiometricUnlockEnabled)
}

func workspaceKey() async throws -> SymmetricKey {
	try await Task.detached { try Unlock.localDbKey(password: workspacePassword, parameters: .fast) }.value
}

func connection(to directory: URL) async throws -> SQLiteConnection {
	try SQLiteConnection(url: AppLock.databaseFile(in: directory), rawKey: try await workspaceKey())
}

func observer(of directory: URL) async throws -> NoteStore {
	try await Unlock.open(password: workspacePassword, in: directory).store
}

extension NoteStore {
	func failAtOnceWhenLocked() throws {
		try connection.execute("PRAGMA busy_timeout = 0")
	}
}
