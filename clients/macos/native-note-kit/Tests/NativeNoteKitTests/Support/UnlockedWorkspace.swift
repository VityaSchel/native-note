import Foundation
import Testing

@testable import NativeNoteKit

let workspacePassword = "correct horse"

@MainActor
func unlockedModel(alarm: Alarm) async throws -> (AppModel, URL) {
	try await unlockedModel { AppModel(directory: $0, scheduler: SaveScheduler(sleep: alarm.sleep)) }
}

@MainActor
func unlockedModel(_ make: (URL) -> AppModel) async throws -> (AppModel, URL) {
	let directory = temporaryDirectory()
	try AppLock.write(.fast, to: AppLock.currentFile(in: directory))
	let model = make(directory)
	model.start()
	await model.unlock(password: workspacePassword)
	try #require(model.phase == .unlocked)
	return (model, directory)
}

@MainActor
func fill(_ model: AppModel, with bodies: [String]) async throws {
	for body in bodies {
		await model.createNote()
		model.edit(try #require(model.selection), body)
	}
	await model.flushPendingSaves()
}

func workspaceKey() async throws -> Data {
	try await Task.detached { try Unlock.localDbKey(password: workspacePassword, parameters: .fast) }.value
}

func connection(to directory: URL) async throws -> SQLiteConnection {
	try SQLiteConnection(url: AppLock.databaseFile(in: directory), rawKey: try await workspaceKey())
}

func observer(of directory: URL) async throws -> NoteStore {
	try await Unlock.open(password: workspacePassword, in: directory)
}
