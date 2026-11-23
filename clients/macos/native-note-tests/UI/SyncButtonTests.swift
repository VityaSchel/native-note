import AppKit
import SwiftUI
import Testing

@testable import NativeNote
@testable import NativeNoteKit

@MainActor @Suite(.scratch)
struct SyncButtonTests {
	private let server = "http://notes.example:8080/"

	private func symbolFrames(_ phase: AppModel.SyncStatus.Phase, reduceMotion: Bool) throws -> [[CGFloat]] {
		let offscreen = OffscreenWindow(
			SyncButton(status: AppModel.SyncStatus(phase: phase, server: server)) { AppModel.SyncStatus() }
				.labelStyle(.iconOnly)
				.buttonStyle(.plain)
				.environment(\._accessibilityReduceMotion, reduceMotion),
			width: 120,
			height: 44
		)
		defer { offscreen.close() }
		offscreen.window.appearance = NSAppearance(named: .aqua)
		offscreen.pump(for: 0.05)
		let symbol = NSRect(x: offscreen.host.bounds.midX - 22, y: offscreen.host.bounds.midY - 22, width: 44, height: 44)
		var frames: [[CGFloat]] = []
		for _ in 0 ..< 40 {
			offscreen.host._renderForTest(interval: 1.0 / 60)
			let rep = try #require(offscreen.host.bitmapImageRepForCachingDisplay(in: symbol))
			offscreen.host.cacheDisplay(in: symbol, to: rep)
			let bytes = try #require(rep.bitmapData)
			try #require(rep.hasAlpha && !rep.isPlanar && rep.bitsPerSample == 8)
			let (stride, alpha) = (rep.bitsPerPixel / 8, rep.bitmapFormat.contains(.alphaFirst) ? 0 : rep.samplesPerPixel - 1)
			frames.append((0 ..< rep.pixelsWide).flatMap { x in (0 ..< rep.pixelsHigh).map { y in CGFloat(bytes[y * rep.bytesPerRow + x * stride + alpha]) / 255 } })
		}
		return frames
	}

	private func inked(_ frame: [CGFloat]) -> Set<Int> {
		let peak = frame.max() ?? 0
		return Set(frame.indices.filter { frame[$0] > peak / 2 })
	}

	private func turn(of frame: [CGFloat], from rest: [CGFloat]) -> Double {
		let resting = inked(rest)
		return Double(inked(frame).symmetricDifference(resting).count) / Double(max(resting.count, 1))
	}

	private func ink(_ frame: [CGFloat]) -> CGFloat {
		frame.reduce(0, +)
	}

	@Test func idleSaysWhenItLastSynced() {
		let button = SyncButton(status: AppModel.SyncStatus(phase: .idle, server: server)) { AppModel.SyncStatus() }

		#expect(button.symbol == "arrow.triangle.2.circlepath")
		#expect(button.value(at: .now) == "Not synced yet")
	}

	@Test func aFailureShowsAWarningWithItsReason() {
		let button = SyncButton(status: AppModel.SyncStatus(phase: .failed("The server could not be reached."), server: server)) { AppModel.SyncStatus() }

		#expect(button.symbol == "exclamationmark.arrow.triangle.2.circlepath")
		#expect(button.value(at: .now) == "Sync failed: The server could not be reached.")
	}

	@Test func theStatusIsReadOnceAsTheValueAndNeverAgainAsAHint() throws {
		let offscreen = OffscreenWindow(SyncButton(status: AppModel.SyncStatus(phase: .failed("The server could not be reached."), server: server)) { AppModel.SyncStatus() }, width: 240, height: 60)
		defer { offscreen.close() }

		let button = try #require(offscreen.attributeTree().first { $0.role == NSAccessibility.Role.button.rawValue && $0.name == "Sync Now" })
		#expect(button.value == "Sync failed: The server could not be reached.")
		#expect(button.help.isEmpty)
	}

	@Test func theButtonReadsInProgressWhileSyncingAndOtherwiseWhatTheSettingsLineSays() throws {
		let synced = Date(timeIntervalSince1970: 1_800_000_000)
		func value(_ phase: AppModel.SyncStatus.Phase, at now: Date = synced.addingTimeInterval(30)) -> String {
			SyncButton(status: AppModel.SyncStatus(phase: phase, server: server, lastSynced: synced)) { AppModel.SyncStatus() }.value(at: now)
		}

		#expect(value(.syncing) == OnboardingLabel.busyValue)
		#expect(value(.failed("The server could not be reached.")) == "Sync failed: The server could not be reached.")
		#expect(value(.idle) == "Last synced just now")
		#expect(value(.idle, at: synced.addingTimeInterval(300)) == SyncSection.statusLine(AppModel.SyncStatus(phase: .idle, lastSynced: synced), now: synced.addingTimeInterval(300)))
		#expect(value(.idle, at: synced.addingTimeInterval(300)) != "Last synced just now")

		let rendered: [(AppModel.SyncStatus.Phase, String)] = [(.syncing, OnboardingLabel.busyValue), (.failed("The server could not be reached."), "Sync failed: The server could not be reached.")]
		for (phase, expected) in rendered {
			let offscreen = OffscreenWindow(SyncButton(status: AppModel.SyncStatus(phase: phase, server: server)) { AppModel.SyncStatus() }, width: 160, height: 44)
			defer { offscreen.close() }
			let button = try #require(offscreen.button("Sync Now"))

			#expect(button.value == expected, "\(phase)")
			#expect(button.isEnabled == (phase != .syncing), "\(phase)")
		}
	}

	@Test func pressingSyncNowReadsOutHowEachSyncEndedAlsoAFailureAlreadyReadOut() async throws {
		let unreachable = "The server could not be reached."
		let announcements = SyncAnnouncements()
		#expect(announcements.phaseChanged(to: .failed(unreachable)) != nil)
		let spoken = Spoken()
		var endings: [AppModel.SyncStatus.Phase] = [.failed(unreachable), .idle]
		let offscreen = OffscreenWindow(
			SyncButton(
				status: AppModel.SyncStatus(phase: .failed(unreachable), server: server),
				sync: {
					let phase = endings.removeFirst()
					return AppModel.SyncStatus(phase: phase, server: server, lastSynced: phase == .idle ? .now : nil)
				},
				announce: { spoken.heard.append($0) },
				announcements: announcements
			),
			width: 160,
			height: 44
		)
		defer { offscreen.close() }

		try offscreen.press("Sync Now")
		await offscreen.pump { spoken.heard.count == 1 }
		try offscreen.press("Sync Now")
		await offscreen.pump { spoken.heard.count == 2 }

		#expect(spoken.heard == ["Sync failed: \(unreachable)", "Last synced just now"])
		#expect(endings.isEmpty)
	}

	@Test func theLibraryReadsOutEachNewFailureReasonOnceAndAgainAfterASyncThatWorked() async throws {
		let (model, _) = try await unlockedModel(alarm: Alarm())
		let spoken = Spoken()
		let offscreen = OffscreenWindow(
			ContentView(exchange: LibraryExchange(model: model), announce: { spoken.heard.append($0) }, syncAnnouncements: SyncAnnouncements()),
			width: 980,
			height: 560
		)
		defer { offscreen.close() }
		let unreachable = "The server could not be reached."
		func reach(_ phase: AppModel.SyncStatus.Phase) async {
			model.sync.status = AppModel.SyncStatus(phase: phase, server: server)
			offscreen.pump(for: 0.02)
			await offscreen.pump { offscreen.window.toolbar?.items.contains { $0.label == "Sync Now" } ?? false }
		}

		await reach(.syncing)
		await reach(.failed(unreachable))
		#expect(spoken.heard == ["Sync failed: \(unreachable)"])

		await reach(.syncing)
		await reach(.failed(unreachable))
		await reach(.syncing)
		await reach(.failed("The server's answer did not arrive."))
		#expect(spoken.heard == ["Sync failed: \(unreachable)", "Sync failed: The server's answer did not arrive."])

		await reach(.syncing)
		await reach(.idle)
		await reach(.syncing)
		await reach(.failed(unreachable))
		#expect(spoken.heard == ["Sync failed: \(unreachable)", "Sync failed: The server's answer did not arrive.", "Sync failed: \(unreachable)"])
	}

	@Test func theToolbarHasSyncNowOnlyWhileSyncIsSetUp() async throws {
		let (model, _) = try await unlockedModel(alarm: Alarm())
		let offscreen = OffscreenWindow(ContentView(exchange: LibraryExchange(model: model)), width: 980, height: 560)
		defer { offscreen.close() }
		offscreen.pump()
		#expect(!(offscreen.window.toolbar?.items.contains { $0.label == "Sync Now" } ?? false))

		model.sync.status = AppModel.SyncStatus(phase: .idle, server: server)
		await offscreen.pump { offscreen.window.toolbar?.items.contains { $0.label == "Sync Now" } ?? false }

		#expect(offscreen.window.toolbar?.items.contains { $0.label == "Sync Now" } ?? false)
	}

	@Test func syncNowWaitsForSetupAndForARunningSync() async throws {
		let (model, _) = try await unlockedModel(alarm: Alarm())
		let exchange = LibraryExchange(model: model)
		#expect(!exchange.canSync)

		model.sync.status = AppModel.SyncStatus(phase: .idle, server: server)
		#expect(exchange.canSync)
		model.sync.status.phase = .syncing
		#expect(!exchange.canSync)
	}

	@Test func theSyncNowCommandReadsOutHowEachSyncEndedAndNothingForOneThatSyncStopped() async {
		let exchange = LibraryExchange(model: .previewing([]))
		let unreachable = "The server could not be reached."
		let spoken = Spoken()
		exchange.announce = { spoken.heard.append($0) }
		exchange.syncAnnouncements = SyncAnnouncements()
		#expect(exchange.syncAnnouncements.phaseChanged(to: .failed(unreachable)) != nil)
		var endings = [
			AppModel.SyncStatus(phase: .failed(unreachable), server: server),
			AppModel.SyncStatus(phase: .idle, server: server, lastSynced: .now),
			AppModel.SyncStatus(),
		]
		exchange.sync = { endings.removeFirst() }

		await exchange.syncNow()
		await exchange.syncNow()
		await exchange.syncNow()

		#expect(spoken.heard == ["Sync failed: \(unreachable)", "Last synced just now"])
		#expect(endings.isEmpty)
	}

	@Test func theSymbolTurnsWhileSyncingAndPulsesInsteadWithReduceMotion() {
		#expect(SyncButton.motion(for: .syncing, reduceMotion: false) == .turning)
		#expect(SyncButton.motion(for: .syncing, reduceMotion: true) == .pulsing)
		for phase in [AppModel.SyncStatus.Phase.off, .idle, .failed("The server could not be reached.")] {
			for reduceMotion in [false, true] {
				#expect(SyncButton.motion(for: phase, reduceMotion: reduceMotion) == .still, "\(phase), Reduce Motion \(reduceMotion)")
			}
		}
	}

	@Test(arguments: [false, true])
	func eachRenderedFrameTurnsTheSyncingSymbolOnlyWithoutReduceMotionAndFadesItInPlaceWithIt(reduceMotion: Bool) throws {
		let frames = try symbolFrames(.syncing, reduceMotion: reduceMotion)
		let inks = frames.map(ink)

		#expect(!inked(frames[0]).isEmpty)
		if reduceMotion {
			#expect(frames.allSatisfy { turn(of: $0, from: frames[0]) < 0.1 })
			#expect(try #require(inks.min()) < 0.8 * (try #require(inks.max())))
		} else {
			#expect(frames.contains { turn(of: $0, from: frames[0]) > 0.2 })
		}
		for phase in [AppModel.SyncStatus.Phase.idle, .failed("The server could not be reached.")] {
			let still = try symbolFrames(phase, reduceMotion: reduceMotion)

			#expect(!inked(still[0]).isEmpty, "\(phase)")
			#expect(still.allSatisfy { $0 == still[0] }, "\(phase)")
		}
	}
}
