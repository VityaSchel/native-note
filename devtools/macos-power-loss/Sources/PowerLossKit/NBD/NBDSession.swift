struct NBDSession {
	enum Ending: Error, Equatable {
		case unknownClientFlags(UInt32)
		case badOptionMagic(UInt64)
		case optionTooLong(UInt32)
		case unknownExport(String)
		case badRequestMagic(UInt32)
	}

	let channel: SocketChannel
	let disk: OrderedDisk
	let export: NBDExport
	let ledger: NBDLedger
	let log: @Sendable (String) -> Void

	func run() {
		do {
			guard try negotiate() else {
				log("nbd: client aborted the handshake")
				return
			}
			try serve()
			log("nbd: client disconnected")
		} catch {
			log("nbd: session ended: \(error)")
		}
	}

	private func negotiate() throws -> Bool {
		var greeting = ByteWriter()
		greeting.append(NBD.Magic.greeting)
		greeting.append(NBD.Magic.option)
		greeting.append(NBD.HandshakeFlag.fixedNewstyle | NBD.HandshakeFlag.noZeroes)
		try channel.send(greeting.bytes)

		let clientFlags: UInt32 = try channel.receive()
		guard clientFlags & ~(NBD.ClientFlag.fixedNewstyle | NBD.ClientFlag.noZeroes) == 0 else {
			throw Ending.unknownClientFlags(clientFlags)
		}
		let noZeroes = clientFlags & NBD.ClientFlag.noZeroes != 0

		while true {
			let magic: UInt64 = try channel.receive()
			guard magic == NBD.Magic.option else { throw Ending.badOptionMagic(magic) }
			let option: UInt32 = try channel.receive()
			let length: UInt32 = try channel.receive()
			guard length <= NBD.maximumOptionLength else { throw Ending.optionTooLong(length) }
			let data = try channel.receive(Int(length))

			switch NBD.Option(rawValue: option) {
			case .exportName:
				let name = String(decoding: data, as: UTF8.self)
				guard serves(name) else { throw Ending.unknownExport(name) }
				guard disk.isPoweredOn else { throw DiskError.poweredOff }
				var reply = ByteWriter()
				reply.append(UInt64(disk.size))
				reply.append(NBD.transmissionFlags)
				if !noZeroes {
					reply.append([UInt8](repeating: 0, count: NBD.exportNamePadding))
				}
				try channel.send(reply.bytes)
				log("nbd: export \"\(name)\" by EXPORT_NAME, client flags \(clientFlags)")
				return true
			case .abort:
				try? reply(to: option, .acknowledge)
				return false
			case .list:
				guard data.isEmpty else {
					try reply(to: option, .invalid)
					continue
				}
				var server = ByteWriter()
				server.append(UInt32(export.name.utf8.count))
				server.append(Array(export.name.utf8))
				try reply(to: option, .server, server.bytes)
				try reply(to: option, .acknowledge)
			case .startTLS:
				try reply(to: option, data.isEmpty ? .policy : .invalid)
			case .info, .go:
				guard let request = try? ExportRequest(data) else {
					try reply(to: option, .invalid)
					continue
				}
				guard serves(request.name) else {
					try reply(to: option, .unknown)
					continue
				}
				guard disk.isPoweredOn else {
					try reply(to: option, .shutdown)
					continue
				}
				try describeExport(to: option, sizes: request.infoRequests.contains(NBD.Info.blockSize.rawValue))
				if option == NBD.Option.go.rawValue {
					log("nbd: export \"\(request.name)\" by GO, client flags \(clientFlags), info requests \(request.infoRequests)")
					return true
				}
			case nil:
				log("nbd: unsupported option \(option)")
				try reply(to: option, .unsupported)
			}
		}
	}

	private func serves(_ name: String) -> Bool {
		name.isEmpty || name == export.name
	}

	private func describeExport(to option: UInt32, sizes: Bool) throws {
		var info = ByteWriter()
		info.append(NBD.Info.export.rawValue)
		info.append(UInt64(disk.size))
		info.append(NBD.transmissionFlags)
		try reply(to: option, .info, info.bytes)
		if sizes {
			var constraints = ByteWriter()
			constraints.append(NBD.Info.blockSize.rawValue)
			constraints.append(export.minimumBlockSize)
			constraints.append(export.preferredBlockSize)
			constraints.append(export.maximumPayload)
			try reply(to: option, .info, constraints.bytes)
		}
		try reply(to: option, .acknowledge)
	}

	private func reply(to option: UInt32, _ type: NBD.OptionReply, _ data: [UInt8] = []) throws {
		var reply = ByteWriter()
		reply.append(NBD.Magic.optionReply)
		reply.append(option)
		reply.append(type.rawValue)
		reply.append(UInt32(data.count))
		reply.append(data)
		try channel.send(reply.bytes)
	}

	private func serve() throws {
		while true {
			let request = try Request(try channel.receive(NBD.requestHeaderSize))
			guard request.magic == NBD.Magic.request else { throw Ending.badRequestMagic(request.magic) }
			let command = NBD.Command(rawValue: request.type)
			if command == .disconnect { return }
			let payload = try receivePayload(of: request, command)
			let checked = validate(request, command)
			guard disk.isPoweredOn else {
				if case .success(let valid) = checked {
					_ = try? perform(valid, request, payload)
				}
				ledger.dropped(command, flags: request.flags)
				continue
			}
			switch checked {
			case .failure(let refusal):
				try refuse(request, refusal)
			case .success(let valid):
				try serve(valid, request, payload)
			}
		}
	}

	private func serve(_ command: NBD.Command, _ request: Request, _ payload: [UInt8]) throws {
		do {
			let data = try perform(command, request, payload)
			ledger.served(command, flags: request.flags)
			try reply(to: request, .none, payload: data)
		} catch DiskError.poweredOff {
			ledger.dropped(command, flags: request.flags)
		} catch {
			try refuse(request, Refusal(.io, "the disk failed: \(error)"))
		}
	}

	private func receivePayload(of request: Request, _ command: NBD.Command?) throws -> [UInt8] {
		guard command == .write else { return [] }
		guard request.length <= export.maximumPayload else {
			try channel.discard(Int(request.length))
			return []
		}
		return try channel.receive(Int(request.length))
	}

	private func validate(_ request: Request, _ command: NBD.Command?) -> Result<NBD.Command, Refusal> {
		guard let command else { return .failure(Refusal(.invalid, "the server does not know this command")) }
		let unsupported = request.flags & ~command.allowedFlags
		if unsupported != 0 {
			return .failure(Refusal(.invalid, "unsupported flags \(NBD.CommandFlag.describe(unsupported))"))
		}
		if command.transfersData, request.length > export.maximumPayload {
			return .failure(Refusal(.invalid, "longer than the \(export.maximumPayload)-byte maximum payload"))
		}
		if let beyondEnd = command.beyondEnd, !request.fits(within: disk.size) {
			return .failure(Refusal(beyondEnd, "beyond the end of the \(disk.size)-byte disk"))
		}
		return .success(command)
	}

	private func perform(_ command: NBD.Command, _ request: Request, _ payload: [UInt8]) throws -> [UInt8] {
		switch command {
		case .read:
			return try disk.read(at: Int(request.offset), count: Int(request.length))
		case .write:
			try disk.write(payload, at: Int(request.offset))
		case .trim, .writeZeroes:
			try disk.zero(at: Int(request.offset), count: Int(request.length))
		case .flush, .cache, .disconnect:
			break
		}
		return []
	}

	private func refuse(_ request: Request, _ refusal: Refusal) throws {
		let rejection = NBDRejection(type: request.type, flags: request.flags, offset: request.offset, length: request.length, error: refusal.failure.rawValue, reason: refusal.reason)
		ledger.refused(rejection)
		log("nbd: rejected \(rejection)")
		try reply(to: request, refusal.failure)
	}

	private func reply(to request: Request, _ failure: NBD.Failure, payload: [UInt8] = []) throws {
		var reply = ByteWriter()
		reply.append(NBD.Magic.simpleReply)
		reply.append(failure.rawValue)
		reply.append(request.cookie)
		reply.append(payload)
		try channel.send(reply.bytes)
	}
}

private struct Refusal: Error {
	let failure: NBD.Failure
	let reason: String

	init(_ failure: NBD.Failure, _ reason: String) {
		self.failure = failure
		self.reason = reason
	}
}

private extension NBD.Command {
	var allowedFlags: UInt16 {
		self == .writeZeroes ? NBD.CommandFlag.forceUnitAccess | NBD.CommandFlag.noHole : NBD.CommandFlag.forceUnitAccess
	}

	var transfersData: Bool {
		self == .read || self == .write
	}

	var beyondEnd: NBD.Failure? {
		switch self {
		case .read, .trim, .cache: .invalid
		case .write, .writeZeroes: .noSpace
		case .flush, .disconnect: nil
		}
	}
}

private struct ExportRequest {
	struct Malformed: Error {}

	let name: String
	let infoRequests: [UInt16]

	init(_ data: [UInt8]) throws {
		var reader = ByteReader(data)
		let nameLength: UInt32 = try reader.integer()
		name = String(decoding: try reader.take(Int(nameLength)), as: UTF8.self)
		let count: UInt16 = try reader.integer()
		infoRequests = try (0 ..< count).map { _ in try reader.integer() }
		guard reader.remaining == 0 else { throw Malformed() }
	}
}

private struct Request {
	let magic: UInt32
	let flags: UInt16
	let type: UInt16
	let cookie: UInt64
	let offset: UInt64
	let length: UInt32

	init(_ header: [UInt8]) throws {
		var reader = ByteReader(header)
		magic = try reader.integer()
		flags = try reader.integer()
		type = try reader.integer()
		cookie = try reader.integer()
		offset = try reader.integer()
		length = try reader.integer()
	}

	func fits(within size: Int) -> Bool {
		offset <= UInt64(size) && UInt64(length) <= UInt64(size) - offset
	}
}
