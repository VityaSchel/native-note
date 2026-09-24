import Foundation
import Testing

@testable import NativeNoteKit

let workspacePassword = "correct horse"

@MainActor
func unlockedModel(alarm: Alarm) async throws -> (AppModel, URL) {
	let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
	try AppLock.write(.fast, to: AppLock.currentFile(in: directory))
	let model = AppModel(directory: directory, scheduler: SaveScheduler(sleep: alarm.sleep))
	model.start()
	await model.unlock(password: workspacePassword)
	try #require(model.phase == .unlocked)
	return (model, directory)
}

func workspaceKey() async throws -> Data {
	try await Task.detached { try Unlock.localDbKey(password: workspacePassword, parameters: .fast) }.value
}

func connection(to directory: URL) async throws -> SQLiteConnection {
	try SQLiteConnection(url: AppLock.database(in: directory), rawKey: try await workspaceKey())
}

func observer(of directory: URL) async throws -> NoteStore {
	try await Unlock.open(password: workspacePassword, in: directory)
}
