import Darwin
import Foundation
import Testing

@testable import PowerLossKit

struct OptionReply: Equatable {
	let option: UInt32
	let type: UInt32
	let data: [UInt8]
}

struct SimpleReply: Equatable {
	let error: UInt32
	let cookie: UInt64
	let data: [UInt8]
}

final class NBDTestClient {
	let descriptor: Int32
	private let channel: SocketChannel

	init(descriptor: Int32) {
		self.descriptor = descriptor
		channel = SocketChannel(descriptor: descriptor)
		var timeout = timeval(tv_sec: 5, tv_usec: 0)
		setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
		var enabled: Int32 = 1
		setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
	}

	deinit {
		close(descriptor)
	}

	func send(_ build: (inout ByteWriter) -> Void) throws {
		var writer = ByteWriter()
		build(&writer)
		try channel.send(writer.bytes)
	}

	func receive(_ count: Int) throws -> [UInt8] {
		try channel.receive(count)
	}

	func receive<T: FixedWidthInteger>(_: T.Type = T.self) throws -> T {
		try channel.receive()
	}

	func greeting() throws -> (magic: UInt64, option: UInt64, flags: UInt16) {
		(try receive(), try receive(), try receive())
	}

	func handshake(flags: UInt32 = NBD.ClientFlag.fixedNewstyle | NBD.ClientFlag.noZeroes) throws {
		_ = try greeting()
		try send { $0.append(flags) }
	}

	func option(_ option: UInt32, _ data: [UInt8] = []) throws {
		try send { writer in
			writer.append(NBD.Magic.option)
			writer.append(option)
			writer.append(UInt32(data.count))
			writer.append(data)
		}
	}

	func optionReply() throws -> OptionReply {
		let magic: UInt64 = try receive()
		#expect(magic == NBD.Magic.optionReply)
		let option: UInt32 = try receive()
		let type: UInt32 = try receive()
		let length: UInt32 = try receive()
		return OptionReply(option: option, type: type, data: try receive(Int(length)))
	}

	func repliesUntilFinal() throws -> [OptionReply] {
		var replies: [OptionReply] = []
		repeat {
			replies.append(try optionReply())
		} while replies.last?.type == NBD.OptionReply.info.rawValue || replies.last?.type == NBD.OptionReply.server.rawValue
		return replies
	}

	func go(_ name: String = "library", infoRequests: [UInt16] = [], option: NBD.Option = .go) throws -> [OptionReply] {
		try self.option(option.rawValue, exportRequest(name, infoRequests))
		return try repliesUntilFinal()
	}

	func connect() throws {
		try handshake()
		let replies = try go()
		#expect(replies.last?.type == NBD.OptionReply.acknowledge.rawValue)
	}

	func request(_ type: UInt16, flags: UInt16 = 0, cookie: UInt64, offset: UInt64 = 0, length: UInt32 = 0, payload: [UInt8] = []) throws {
		try send { writer in
			writer.append(NBD.Magic.request)
			writer.append(flags)
			writer.append(type)
			writer.append(cookie)
			writer.append(offset)
			writer.append(length)
			writer.append(payload)
		}
	}

	func reply(carrying count: Int = 0) throws -> SimpleReply {
		let magic: UInt32 = try receive()
		#expect(magic == NBD.Magic.simpleReply)
		let error: UInt32 = try receive()
		let cookie: UInt64 = try receive()
		return SimpleReply(error: error, cookie: cookie, data: error == 0 ? try receive(count) : [])
	}

	func write(_ bytes: [UInt8], at offset: Int, flags: UInt16 = 0, cookie: UInt64 = 1) throws -> SimpleReply {
		try request(NBD.Command.write.rawValue, flags: flags, cookie: cookie, offset: UInt64(offset), length: UInt32(bytes.count), payload: bytes)
		return try reply()
	}

	func read(at offset: Int, count: Int, cookie: UInt64 = 2) throws -> SimpleReply {
		try request(NBD.Command.read.rawValue, cookie: cookie, offset: UInt64(offset), length: UInt32(count))
		return try reply(carrying: count)
	}

	func flush(cookie: UInt64 = 3) throws -> SimpleReply {
		try request(NBD.Command.flush.rawValue, cookie: cookie)
		return try reply()
	}

	var hasUnreadReply: Bool {
		var byte: UInt8 = 0
		return recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT) > 0
	}

	var isClosedByServer: Bool {
		var byte: UInt8 = 0
		return Darwin.read(descriptor, &byte, 1) == 0
	}
}

func exportRequest(_ name: String, _ infoRequests: [UInt16] = []) -> [UInt8] {
	var writer = ByteWriter()
	writer.append(UInt32(name.utf8.count))
	writer.append(Array(name.utf8))
	writer.append(UInt16(infoRequests.count))
	for request in infoRequests {
		writer.append(request)
	}
	return writer.bytes
}

func pairedClient(of server: NBDServer) -> NBDTestClient {
	var descriptors: [Int32] = [-1, -1]
	#expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
	server.adopt(descriptors[0])
	return NBDTestClient(descriptor: descriptors[1])
}

func settle(_ condition: () -> Bool) {
	let deadline = Date.now.addingTimeInterval(5)
	while !condition(), Date.now < deadline {
		usleep(1_000)
	}
}
