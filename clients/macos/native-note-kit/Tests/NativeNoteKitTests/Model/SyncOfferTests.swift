import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.scratch, .syncServer, .timeLimit(.minutes(1)))
struct SyncOfferTests {
	private struct Offline: SyncTransport {
		func post(_ body: Data) async throws -> Data {
			throw URLError(.cannotConnectToHost)
		}
	}

	private func freshMac(_ server: SyncServer? = nil) -> (AppModel, URL) {
		let directory = temporaryDirectory()
		let model = AppModel(
			directory: directory,
			makeParameters: { .fast },
			calibrate: { UnlockParameters.fast.argon },
			keyStore: FakeKeyStore(),
			makeTransport: { _ in server.map { TestTransport($0) as any SyncTransport } ?? Offline() },
			syncDelay: .seconds(3600)
		)
		model.start()
		return (model, directory)
	}

	@Test func settingUpTheLibraryStartsOnboardingOnceAndLockingEndsIt() async throws {
		let (model, _) = freshMac()
		try #require(model.phase == .needsSetup)

		await model.submit(password: workspacePassword)
		#expect(model.phase == .unlocked)
		#expect(model.isOnboarding)

		await model.lock()
		#expect(!model.isOnboarding)
		await model.submit(password: workspacePassword)
		#expect(model.phase == .unlocked)
		#expect(!model.isOnboarding)
	}

	@Test func notNowLeavesSyncToSettings() async throws {
		let (model, _) = freshMac()
		await model.submit(password: workspacePassword)

		model.finishOnboarding()

		#expect(!model.isOnboarding)
		#expect(model.syncStatus.server == nil)
	}

	@Test func aWipedMacThatJoinsDuringOnboardingStartsWithItsSyncedNotes() async throws {
		let server = try SyncServer()
		let (first, _) = try await syncingModel(server, idle: .seconds(3600))
		try await fill(first, with: ["kept on the server", "and a second note"])
		let phrase = try await setUpSync(first, server)
		await first.syncNow()
		try #require(first.syncStatus.phase == .idle)

		let (wiped, _) = freshMac(server)
		await wiped.submit(password: "a new password")
		try #require(wiped.isOnboarding)
		#expect(await wiped.joinSync(server: server.url.absoluteString, apiKey: try apiKeyText(server), phrase: entry(phrase.words)) == nil)
		wiped.finishOnboarding()
		await wiped.syncNow()

		#expect(Set(wiped.notes.map(\.body)) == ["kept on the server", "and a second note"])
	}
}
