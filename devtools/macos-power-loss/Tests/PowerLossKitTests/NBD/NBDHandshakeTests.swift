import Foundation
import Testing

@testable import PowerLossKit

@Suite(.timeLimit(.minutes(1)))
struct NBDHandshakeTests {
	private let scratch: ScratchDisk
	private let server: NBDServer

	init() throws {
		scratch = try ScratchDisk()
		server = NBDServer(disk: scratch.disk)
	}

	private func finish() {
		server.stop()
		scratch.remove()
	}

	private var exportInfo: [UInt8] {
		var writer = ByteWriter()
		writer.append(NBD.Info.export.rawValue)
		writer.append(UInt64(ScratchDisk.size))
		writer.append(UInt16(0b0110_1101))
		return writer.bytes
	}

	@Test func theServerGreetsWithFixedNewstyleWithoutZeroPadding() throws {
		defer { finish() }
		let client = pairedClient(of: server)

		let greeting = try client.greeting()

		#expect(greeting.magic == 0x4E42_444D_4147_4943)
		#expect(greeting.option == 0x4948_4156_454F_5054)
		#expect(greeting.flags == 0b11)
	}

	@Test func unknownClientFlagsEndTheSession() throws {
		defer { finish() }
		let client = pairedClient(of: server)

		try client.handshake(flags: 0b101)

		#expect(client.isClosedByServer)
	}

	@Test(arguments: ["library", ""])
	func goOnTheExportDescribesItAndEntersTransmission(name: String) throws {
		defer { finish() }
		let client = pairedClient(of: server)
		try client.handshake()

		let replies = try client.go(name)

		#expect(replies == [
			OptionReply(option: 7, type: 3, data: exportInfo),
			OptionReply(option: 7, type: 1, data: []),
		])
		#expect(try client.read(at: 10, count: 4) == SimpleReply(error: 0, cookie: 2, data: [10, 11, 12, 13]))
	}

	@Test func goAskingForSizeConstraintsAlsoReportsThem() throws {
		defer { finish() }
		let client = pairedClient(of: server)
		try client.handshake()

		let replies = try client.go(infoRequests: [NBD.Info.blockSize.rawValue, 1])

		var constraints = ByteWriter()
		constraints.append(UInt16(3))
		constraints.append(UInt32(512))
		constraints.append(UInt32(4_096))
		constraints.append(UInt32(32 << 20))
		#expect(replies == [
			OptionReply(option: 7, type: 3, data: exportInfo),
			OptionReply(option: 7, type: 3, data: constraints.bytes),
			OptionReply(option: 7, type: 1, data: []),
		])
	}

	@Test func infoDescribesTheExportWithoutEnteringTransmission() throws {
		defer { finish() }
		let client = pairedClient(of: server)
		try client.handshake()

		let info = try client.go(option: .info)
		let go = try client.go()

		#expect(info.map(\.option) == [6, 6])
		#expect(info.map(\.data) == go.map(\.data))
		#expect(try client.read(at: 0, count: 1).error == 0)
	}

	@Test func anUnknownExportIsRefusedAndNegotiationContinues() throws {
		defer { finish() }
		let client = pairedClient(of: server)
		try client.handshake()

		let refused = try client.go("elsewhere")
		let accepted = try client.go()

		#expect(refused == [OptionReply(option: 7, type: 0x8000_0006, data: [])])
		#expect(accepted.last?.type == 1)
	}

	@Test func malformedExportRequestsAreInvalidAndNegotiationContinues() throws {
		defer { finish() }
		let client = pairedClient(of: server)
		try client.handshake()

		try client.option(7, [0, 0, 0, 200] + Array("library".utf8) + [0, 0])
		let overlongName = try client.optionReply()
		try client.option(7, exportRequest("library") + [0])
		let trailingByte = try client.optionReply()
		try client.option(7, [0, 0])
		let truncated = try client.optionReply()

		for reply in [overlongName, trailingByte, truncated] {
			#expect(reply == OptionReply(option: 7, type: 0x8000_0003, data: []))
		}
		#expect(try client.go().last?.type == 1)
	}

	@Test func exportNameWithoutZeroesEntersTransmissionAfterTenBytes() throws {
		defer { finish() }
		let client = pairedClient(of: server)
		try client.handshake()

		try client.option(1, Array("library".utf8))
		let size: UInt64 = try client.receive()
		let flags: UInt16 = try client.receive()

		#expect(size == UInt64(ScratchDisk.size))
		#expect(flags == 0b0110_1101)
		#expect(try client.read(at: 1, count: 2).data == [1, 2])
	}

	@Test func exportNameForAnOlderClientPadsWithZeroes() throws {
		defer { finish() }
		let client = pairedClient(of: server)
		try client.handshake(flags: NBD.ClientFlag.fixedNewstyle)

		try client.option(1)
		let reply = try client.receive(134)

		#expect(reply[8 ..< 10] == [0, 0b0110_1101])
		#expect(reply[10...].allSatisfy { $0 == 0 })
		#expect(try client.read(at: 1, count: 2).data == [1, 2])
	}

	@Test func exportNameForAnUnknownExportEndsTheSession() throws {
		defer { finish() }
		let client = pairedClient(of: server)
		try client.handshake()

		try client.option(1, Array("elsewhere".utf8))

		#expect(client.isClosedByServer)
	}

	@Test func unsupportedOptionsAreRefusedWithoutLosingTheStream() throws {
		defer { finish() }
		let client = pairedClient(of: server)
		try client.handshake()

		try client.option(8)
		let structuredReplies = try client.optionReply()
		try client.option(10, exportRequest("library"))
		let metaContext = try client.optionReply()
		try client.option(5)
		let tls = try client.optionReply()

		#expect(structuredReplies == OptionReply(option: 8, type: 0x8000_0001, data: []))
		#expect(metaContext == OptionReply(option: 10, type: 0x8000_0001, data: []))
		#expect(tls == OptionReply(option: 5, type: 0x8000_0002, data: []))
		#expect(try client.go().last?.type == 1)
	}

	@Test func listNamesTheOneExport() throws {
		defer { finish() }
		let client = pairedClient(of: server)
		try client.handshake()

		try client.option(3)
		let listed = try client.repliesUntilFinal()
		try client.option(3, [1])
		let withData = try client.optionReply()

		#expect(listed == [
			OptionReply(option: 3, type: 2, data: [0, 0, 0, 7] + Array("library".utf8)),
			OptionReply(option: 3, type: 1, data: []),
		])
		#expect(withData.type == 0x8000_0003)
	}

	@Test func abortIsAcknowledgedAndEndsTheSession() throws {
		defer { finish() }
		let client = pairedClient(of: server)
		try client.handshake()

		try client.option(2)

		#expect(try client.optionReply() == OptionReply(option: 2, type: 1, data: []))
		#expect(client.isClosedByServer)
	}

	@Test func aBadOptionMagicEndsTheSession() throws {
		defer { finish() }
		let client = pairedClient(of: server)
		try client.handshake()

		try client.send { $0.append(UInt64(0x1234)) }

		#expect(client.isClosedByServer)
	}

	@Test func negotiationWhileThePowerIsCutIsRefused() throws {
		defer { finish() }
		server.cutPower(tearingWith: nil)
		let goClient = pairedClient(of: server)
		let exportNameClient = pairedClient(of: server)

		try goClient.handshake()
		let refused = try goClient.go()
		try exportNameClient.handshake()
		try exportNameClient.option(1, Array("library".utf8))

		#expect(refused == [OptionReply(option: 7, type: 0x8000_0007, data: [])])
		#expect(exportNameClient.isClosedByServer)
		try server.restorePower()
		#expect(goClient.isClosedByServer)
		let afterPowerReturns = pairedClient(of: server)
		try afterPowerReturns.handshake()
		#expect(try afterPowerReturns.go().last?.type == 1)
	}
}
