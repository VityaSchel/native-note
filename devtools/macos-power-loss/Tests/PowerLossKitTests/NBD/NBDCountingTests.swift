import Foundation
import Synchronization
import Testing

@testable import PowerLossKit

private final class LogLines: Sendable {
	private let lines = Mutex<[String]>([])

	var all: [String] { lines.withLock { $0 } }

	func append(_ line: String) {
		lines.withLock { $0.append(line) }
	}
}

@Suite(.timeLimit(.minutes(1)))
struct NBDCountingTests {
	private let scratch: ScratchDisk
	private let logged = LogLines()
	private let server: NBDServer
	private let client: NBDTestClient

	init() throws {
		scratch = try ScratchDisk()
		server = NBDServer(disk: scratch.disk, export: NBDExport(maximumPayload: 8_192), log: { [logged] in logged.append($0) })
		client = pairedClient(of: server)
		try client.connect()
	}

	private func finish() {
		server.stop()
		scratch.remove()
	}

	private var rejectionLines: [String] {
		logged.all.filter { $0.hasPrefix("nbd: rejected ") }
	}

	@Test func everyServedCommandIsCountedByItsType() throws {
		defer { finish() }
		let forceUnitAccess = NBD.CommandFlag.forceUnitAccess

		_ = try client.read(at: 0, count: 16)
		_ = try client.read(at: 16, count: 16)
		_ = try client.write(filled(1, 512), at: 0)
		_ = try client.write(filled(2, 512), at: 512, flags: forceUnitAccess)
		_ = try client.flush()
		try client.request(NBD.Command.trim.rawValue, cookie: 5, offset: 4_096, length: 4_096)
		_ = try client.reply()
		try client.request(NBD.Command.writeZeroes.rawValue, flags: forceUnitAccess | NBD.CommandFlag.noHole, cookie: 6, offset: 8_192, length: 512)
		_ = try client.reply()
		try client.request(NBD.Command.cache.rawValue, cookie: 7, length: 512)
		_ = try client.reply()

		#expect(server.activity == DiskActivity(reads: 2, writes: 2, forcedWrites: 2, flushes: 1, trims: 1, writeZeroes: 1, cache: 1))
		#expect(server.rejections.isEmpty)
		#expect(rejectionLines.isEmpty)
	}

	@Test func aFlushCarryingForceUnitAccessIsServedAsAFlush() throws {
		defer { finish() }
		_ = try client.write(filled(3, 512), at: 0)

		try client.request(NBD.Command.flush.rawValue, flags: NBD.CommandFlag.forceUnitAccess, cookie: 8)

		#expect(try client.reply() == SimpleReply(error: 0, cookie: 8, data: []))
		#expect(server.activity == DiskActivity(writes: 1, flushes: 1))
	}

	@Test func everyRejectedRequestIsCountedLoggedAndKeptWithItsDetails() throws {
		defer { finish() }

		try client.request(99, flags: 1 << 3, cookie: 10, offset: 7, length: 3)
		_ = try client.reply()
		try client.request(NBD.Command.flush.rawValue, flags: 1 << 2, cookie: 11)
		_ = try client.reply()
		_ = try client.write(filled(1, 8), at: ScratchDisk.size - 4)
		_ = try client.write(filled(1, 8_193), at: 0)
		_ = try client.read(at: 0, count: 8_193)

		#expect(server.activity == DiskActivity(rejected: 4, unknown: 1))
		#expect(server.rejections == [
			NBDRejection(type: 99, flags: 1 << 3, offset: 7, length: 3, error: 22, reason: "the server does not know this command"),
			NBDRejection(type: 3, flags: 1 << 2, offset: 0, length: 0, error: 22, reason: "unsupported flags 0x0004 (DF)"),
			NBDRejection(type: 1, flags: 0, offset: UInt64(ScratchDisk.size - 4), length: 8, error: 28, reason: "beyond the end of the 65536-byte disk"),
			NBDRejection(type: 1, flags: 0, offset: 0, length: 8_193, error: 22, reason: "longer than the 8192-byte maximum payload"),
			NBDRejection(type: 0, flags: 0, offset: 0, length: 8_193, error: 22, reason: "longer than the 8192-byte maximum payload"),
		])
		#expect(rejectionLines == [
			"nbd: rejected unknown command 99 flags 0x0008 (REQ_ONE) offset 7 length 3: the server does not know this command, answered EINVAL",
			"nbd: rejected FLUSH flags 0x0004 (DF) offset 0 length 0: unsupported flags 0x0004 (DF), answered EINVAL",
			"nbd: rejected WRITE flags 0x0000 offset 65532 length 8: beyond the end of the 65536-byte disk, answered ENOSPC",
			"nbd: rejected WRITE flags 0x0000 offset 0 length 8193: longer than the 8192-byte maximum payload, answered EINVAL",
			"nbd: rejected READ flags 0x0000 offset 0 length 8193: longer than the 8192-byte maximum payload, answered EINVAL",
		])
	}

	@Test func onlyTheFirstRejectionsAreKeptButEveryOneIsCountedAndLogged() throws {
		defer { finish() }
		let count = NBDLedger.keptRejections + 3

		for cookie in 0 ..< count {
			try client.request(42, cookie: UInt64(cookie))
			_ = try client.reply()
		}

		#expect(server.activity == DiskActivity(unknown: count))
		#expect(server.rejections.count == NBDLedger.keptRejections)
		#expect(rejectionLines.count == count)
	}

	@Test func aDisconnectIsNotCounted() throws {
		defer { finish() }

		try client.request(NBD.Command.disconnect.rawValue, cookie: 1)

		#expect(client.isClosedByServer)
		#expect(server.activity == DiskActivity())
	}
}

struct NBDCommandFlagTests {
	@Test(arguments: [
		(UInt16(0), "0x0000"),
		(NBD.CommandFlag.forceUnitAccess, "0x0001 (FUA)"),
		(NBD.CommandFlag.forceUnitAccess | NBD.CommandFlag.noHole, "0x0003 (FUA|NO_HOLE)"),
		(UInt16(1 << 5 | 1 << 4), "0x0030 (FAST_ZERO|PAYLOAD_LEN)"),
		(UInt16(1 << 15), "0x8000 (bit 15)"),
	])
	func flagsAreShownInHexWithTheirNames(_ flags: UInt16, _ shown: String) {
		#expect(NBD.CommandFlag.describe(flags) == shown)
	}
}
