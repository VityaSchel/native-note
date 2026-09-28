import Foundation
import Testing

@testable import PowerLossKit

@Suite(.timeLimit(.minutes(1)))
struct NBDTransmissionTests {
	private let scratch: ScratchDisk
	private let server: NBDServer
	private let client: NBDTestClient

	init() throws {
		scratch = try ScratchDisk()
		server = NBDServer(disk: scratch.disk, export: NBDExport(maximumPayload: 8_192))
		client = pairedClient(of: server)
		try client.connect()
	}

	private func finish() {
		server.stop()
		scratch.remove()
	}

	@Test func writesReadBackAtUnalignedOffsetsAndEchoTheirCookies() throws {
		defer { finish() }
		var model = DiskModel()
		model.write([9, 8, 7, 6, 5, 4, 3], at: 1_001)

		let written = try client.write([9, 8, 7, 6, 5, 4, 3], at: 1_001, cookie: 0xDEAD_BEEF_0000_0001)
		let read = try client.read(at: 995, count: 20, cookie: .max)

		#expect(written == SimpleReply(error: 0, cookie: 0xDEAD_BEEF_0000_0001, data: []))
		#expect(read == SimpleReply(error: 0, cookie: .max, data: Array(model.bytes[995 ..< 1_015])))
		#expect(try scratch.durable == model.bytes)
	}

	@Test func aFlushIsAnsweredAndCountedWithNothingLeftToWrite() throws {
		defer { finish() }
		var model = DiskModel()
		model.write(filled(5, 4_096), at: 4_096)

		_ = try client.write(filled(5, 4_096), at: 4_096)
		let durableBeforeTheFlush = try scratch.durable
		let flushed = try client.flush()

		#expect(flushed == SimpleReply(error: 0, cookie: 3, data: []))
		#expect(server.activity == DiskActivity(writes: 1, flushes: 1))
		#expect(durableBeforeTheFlush == model.bytes)
	}

	@Test func aForcedWriteIsDurableBeforeItsReply() throws {
		defer { finish() }
		var model = DiskModel()
		model.write(filled(6, 512), at: 512)

		let written = try client.write(filled(6, 512), at: 512, flags: NBD.CommandFlag.forceUnitAccess)

		#expect(written.error == 0)
		#expect(server.activity == DiskActivity(writes: 1, forcedWrites: 1))
		#expect(try scratch.durable == model.bytes)
	}

	@Test func requestsBeyondTheEndFailWithoutLosingTheStream() throws {
		defer { finish() }
		let size = ScratchDisk.size

		let read = try client.read(at: size - 4, count: 8)
		let written = try client.write(filled(1, 8), at: size - 4)
		try client.request(NBD.Command.read.rawValue, cookie: 4, offset: .max, length: 1)
		let wrapped = try client.reply()

		#expect(read == SimpleReply(error: 22, cookie: 2, data: []))
		#expect(written == SimpleReply(error: 28, cookie: 1, data: []))
		#expect(wrapped.error == 22)
		#expect(try client.read(at: size - 4, count: 4).data == Array(DiskModel().bytes[(size - 4)...]))
		#expect(try scratch.durable == DiskModel().bytes)
	}

	@Test func payloadsOverTheMaximumAreRefusedAndSkipped() throws {
		defer { finish() }

		let written = try client.write(filled(1, 8_193), at: 0)
		let read = try client.read(at: 0, count: 8_193)

		#expect(written.error == 22)
		#expect(read.error == 22)
		#expect(try client.write([4], at: 0).error == 0)
		#expect(try client.read(at: 0, count: 2).data == [4, 1])
	}

	@Test func unknownCommandsAndFlagsAreInvalid() throws {
		defer { finish() }

		try client.request(99, cookie: 10)
		let unknownCommand = try client.reply()
		try client.request(NBD.Command.read.rawValue, flags: 1 << 2, cookie: 11, length: 1)
		let dontFragment = try client.reply()
		let noHoleWrite = try client.write([1], at: 0, flags: NBD.CommandFlag.noHole)
		try client.request(NBD.Command.writeZeroes.rawValue, flags: 1 << 4, cookie: 12, length: 1)
		let fastZero = try client.reply()

		#expect(unknownCommand == SimpleReply(error: 22, cookie: 10, data: []))
		#expect(dontFragment.error == 22)
		#expect(noHoleWrite.error == 22)
		#expect(fastZero.error == 22)
		#expect(try client.read(at: 0, count: 1).data == [0])
	}

	@Test func trimAndWriteZeroesReadBackAsZeros() throws {
		defer { finish() }
		let size = UInt64(ScratchDisk.size)

		try client.request(NBD.Command.trim.rawValue, cookie: 20, offset: 100, length: 5_000)
		let trimmed = try client.reply()
		try client.request(NBD.Command.writeZeroes.rawValue, flags: NBD.CommandFlag.noHole | NBD.CommandFlag.forceUnitAccess, cookie: 21, offset: 9_000, length: 10)
		let zeroed = try client.reply()
		try client.request(NBD.Command.trim.rawValue, cookie: 22, offset: size - 1, length: 2)
		let trimBeyond = try client.reply()
		try client.request(NBD.Command.writeZeroes.rawValue, cookie: 23, offset: size - 1, length: 2)
		let zeroBeyond = try client.reply()

		#expect([trimmed.error, zeroed.error, trimBeyond.error, zeroBeyond.error] == [0, 0, 22, 28])
		#expect(try client.read(at: 100, count: 5_000).data == filled(0, 5_000))
		#expect(try scratch.durable[100 ..< 5_100].allSatisfy { $0 == 0 })
		#expect(try scratch.durable[9_000 ..< 9_010].allSatisfy { $0 == 0 })
	}

	@Test func aCacheHintSucceedsWithoutEffect() throws {
		defer { finish() }

		try client.request(NBD.Command.cache.rawValue, cookie: 30, offset: 0, length: 4_096)

		#expect(try client.reply() == SimpleReply(error: 0, cookie: 30, data: []))
		#expect(try scratch.durable == DiskModel().bytes)
	}

	@Test func disconnectEndsTheSession() throws {
		defer { finish() }

		try client.request(NBD.Command.disconnect.rawValue, cookie: 40)

		#expect(client.isClosedByServer)
		settle { server.sessionCount == 0 }
		#expect(server.sessionCount == 0)
	}

	@Test func aBadRequestMagicEndsTheSession() throws {
		defer { finish() }

		try client.send { writer in
			writer.append(UInt32(0x1256_0953))
			writer.append(filled(0, 24))
		}

		#expect(client.isClosedByServer)
	}
}
