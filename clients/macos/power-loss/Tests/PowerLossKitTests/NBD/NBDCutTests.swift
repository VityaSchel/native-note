import Foundation
import Testing

@testable import PowerLossKit

@Suite(.timeLimit(.minutes(1)))
struct NBDCutTests {
	private let scratch: ScratchDisk
	private let server: NBDServer
	private let client: NBDTestClient

	init() throws {
		scratch = try ScratchDisk()
		server = NBDServer(disk: scratch.disk)
		client = pairedClient(of: server)
		try client.connect()
	}

	private func finish() {
		server.stop()
		scratch.remove()
	}

	private func sendWrite(_ bytes: [UInt8], at offset: Int, cookie: UInt64) throws {
		try client.request(NBD.Command.write.rawValue, cookie: cookie, offset: UInt64(offset), length: UInt32(bytes.count), payload: bytes)
	}

	@Test func anAcknowledgedWriteSurvivesACutAndAnUnacknowledgedOneDoesNot() throws {
		defer { finish() }
		var model = DiskModel()
		model.write(filled(1, 4_096), at: 0)

		#expect(try client.write(filled(1, 4_096), at: 0).error == 0)
		server.cutPower(tearingWith: nil)
		try sendWrite(filled(2, 4_096), at: 4_096, cookie: 2)
		settle { server.cut.dropped.writes == 1 }

		#expect(server.cut == CutReport(torn: nil, dropped: DiskActivity(writes: 1)))
		#expect(!client.hasUnreadReply)
		#expect(try scratch.durable == model.bytes)
		try server.restorePower()
		let rebooted = pairedClient(of: server)
		try rebooted.connect()
		#expect(try rebooted.read(at: 0, count: 8_192).data == Array(model.bytes[0 ..< 8_192]))
	}

	@Test(arguments: 0 ..< 16 as Range<UInt64>)
	func requestsQueuedBehindTheCutAreNeverAppliedAndOnlyTheFirstWriteIsTorn(seed: UInt64) throws {
		defer { finish() }
		var model = DiskModel()
		model.write(filled(1, 4_096), at: 0)
		#expect(try client.write(filled(1, 4_096), at: 0).error == 0)

		server.cutPower(tearingWith: seed)
		try sendWrite(filled(2, 3 * 4_096), at: 4_096, cookie: 2)
		try client.request(NBD.Command.read.rawValue, cookie: 3, length: 4_096)
		try sendWrite(filled(3, 4_096), at: 20_480, cookie: 4)
		try client.request(NBD.Command.writeZeroes.rawValue, cookie: 5, length: 4_096)
		try client.request(NBD.Command.flush.rawValue, cookie: 6)
		settle { server.cut.dropped.flushes == 1 }

		let torn = try #require(server.cut.torn)
		#expect(torn.offset == 4_096)
		#expect(torn.length == 3 * 4_096)
		#expect(torn.kept.isMultiple(of: 4_096))
		#expect(server.cut.dropped == DiskActivity(reads: 1, writes: 2, flushes: 1, writeZeroes: 1))
		#expect(!client.hasUnreadReply)
		model.write(filled(2, torn.kept), at: 4_096)
		#expect(try scratch.durable == model.bytes)
		try server.restorePower()
		#expect(client.isClosedByServer)
		#expect(try scratch.durable == model.bytes)
	}

	@Test func aRequestTheServerWouldRefuseGetsNoAnswerAfterTheCutAndTearsNothing() throws {
		defer { finish() }

		server.cutPower(tearingWith: 7)
		try client.request(99, cookie: 1)
		try sendWrite(filled(4, 8), at: ScratchDisk.size - 4, cookie: 2)
		try client.request(NBD.Command.cache.rawValue, cookie: 3, length: 512)
		settle { server.cut.dropped.cache == 1 }

		#expect(server.cut == CutReport(torn: nil, dropped: DiskActivity(writes: 1, cache: 1, unknown: 1)))
		#expect(server.rejections.isEmpty)
		#expect(!client.hasUnreadReply)
		#expect(try scratch.durable == DiskModel().bytes)
	}

	@Test func disconnectingAfterTheCutEndsTheSessionWithoutApplyingItsLastRequests() throws {
		defer { finish() }
		server.cutPower(tearingWith: nil)
		try sendWrite(filled(5, 8_192), at: 0, cookie: 1)
		try client.request(NBD.Command.writeZeroes.rawValue, cookie: 2, offset: 16_384, length: 4_096)
		settle { server.cut.dropped.writeZeroes == 1 }

		server.disconnect()

		#expect(client.isClosedByServer)
		settle { server.sessionCount == 0 }
		#expect(server.sessionCount == 0)
		#expect(!server.disk.isPoweredOn)
		#expect(server.cut == CutReport(torn: nil, dropped: DiskActivity(writes: 1, writeZeroes: 1)))
		try server.restorePower()
		let rebooted = pairedClient(of: server)
		try rebooted.connect()
		#expect(try rebooted.read(at: 0, count: ScratchDisk.size).data == DiskModel().bytes)
		#expect(try scratch.durable == DiskModel().bytes)
	}

	@Test func servedRequestsBeforeTheCutStayCountedApartFromDroppedOnes() throws {
		defer { finish() }

		_ = try client.write(filled(1, 512), at: 0)
		_ = try client.flush()
		server.cutPower(tearingWith: nil)
		try client.request(NBD.Command.flush.rawValue, cookie: 9)
		settle { server.cut.dropped.flushes == 1 }

		#expect(server.activity == DiskActivity(writes: 1, flushes: 1))
		#expect(server.cut.dropped == DiskActivity(flushes: 1))
	}
}
