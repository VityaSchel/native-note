import Foundation
import Testing

@testable import NativeNoteKit

/// Phase 5's exit: devices converge under packet loss, mid-request kills and clock skew, losing no write and never livelocking.
@MainActor
struct SyncConvergenceTests {
	private struct Ledger {
		/// Every text any device wrote, each unique.
		var written: Set<String> = []
		/// Texts a device had in front of it when it edited or deleted the note, so it superseded them knowingly.
		var superseded: Set<String> = []
	}

	@Test(arguments: [UInt64(0x5eed_0001), 0x5eed_0002, 0x5eed_0003])
	func devicesConvergeUnderLossKillsAndSkewWithoutLosingAWrite(seed: UInt64) async throws {
		let server = try SyncServer()
		let devices = [
			try await SyncDevice(server),
			try await SyncDevice(server, skew: .seconds(3 * 3600)),
			try await SyncDevice(server, skew: .seconds(-2 * 86400)),
		]
		var random = SeededGenerator(seed: seed)
		var ledger = Ledger()
		var syncs = 0
		var failed = 0

		for step in 0 ..< 240 {
			let device = devices[Int.random(in: devices.indices, using: &random)]
			let live = try await device.live().sorted { $0.key.uuidString < $1.key.uuidString }
			switch Int.random(in: 0 ..< 10, using: &random) {
			case 0 ..< 3 where !live.isEmpty:
				let (id, body) = live[Int.random(in: live.indices, using: &random)]
				let text = "step \(step) on \(ObjectIdentifier(device).hashValue)"
				ledger.superseded.insert(body)
				ledger.written.insert(text)
				try await device.write(text, to: id)
			case 3 where !live.isEmpty:
				let (id, body) = live[Int.random(in: live.indices, using: &random)]
				ledger.superseded.insert(body)
				try await device.delete(id)
			case 0 ..< 5:
				let text = "step \(step), new"
				ledger.written.insert(text)
				try await device.write(text)
			default:
				syncs += 1
				let fault: TestTransport.Fault = switch Int.random(in: 0 ..< 10, using: &random) {
				case 0, 1: .dropRequest
				case 2, 3: .dropResponse
				case 4, 5: .killServer
				default: .none
				}
				device.transport.failNext(fault)
				do {
					try await device.sync()
				} catch {
					failed += 1
				}
			}
		}

		for _ in 0 ..< 3 {
			for device in devices { try await device.sync() }
		}
		var quiet = true
		for device in devices {
			let applied = try await device.sync()
			quiet = quiet && applied.changed.isEmpty && applied.problems.isEmpty
			#expect(try await device.dirty.isEmpty)
		}
		#expect(quiet, "a further round still changed something")

		let converged = try await devices[0].live()
		for device in devices.dropFirst() {
			#expect(try await device.live() == converged)
		}
		let surviving = Set(converged.values)
		let lost = ledger.written.subtracting(surviving).subtracting(ledger.superseded)
		#expect(lost.isEmpty, "lost writes: \(lost.sorted())")
		#expect(syncs > 40 && failed > 10, "\(syncs) syncs, \(failed) failed")
	}
}
