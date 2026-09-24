import Foundation

nonisolated struct ZipEntry: Equatable, Sendable {
	let name: String
	let data: Data
	let modified: Date
}

nonisolated enum ZipArchive {
	enum Failure: Error, Equatable {
		case notAZip
		case unsupported(Feature)
		case damaged(Damage)
		case unsafeName
		case tooLarge
	}

	enum Feature: Equatable, Sendable {
		case compression(method: UInt16)
		case encryption
		case zip64
		case multipleDisks
		case dataDescriptor
		case unknownFlags(UInt16)
	}

	enum Damage: Equatable, Sendable {
		case truncated
		case outOfBounds
		case inconsistent
		case overlapping
		case checksum
	}

	static func write(_ entries: [ZipEntry]) throws -> Data {
		guard entries.count < Limit.entries else { throw Failure.tooLarge }
		let names = try entries.map { try encodedName($0.name) }
		let directoryOffset = names.reduce(0) { $0 + Layout.localHeader + $1.count } + entries.reduce(0) { $0 + $1.data.count }
		let directorySize = names.reduce(0) { $0 + Layout.centralHeader + $1.count }
		guard directoryOffset < Limit.size, directorySize < Limit.size else { throw Failure.tooLarge }

		var archive = Output(capacity: directoryOffset + directorySize + Layout.endRecord)
		var directory = Output(capacity: directorySize)
		for (entry, name) in zip(entries, names) {
			let timestamp = dosTimestamp(of: entry.modified)
			let size = UInt32(entry.data.count)
			let header = Header(
				flags: Flag.utf8, method: 0, time: timestamp.time, date: timestamp.date,
				crc: crc32(entry.data), compressedSize: size, size: size, name: name
			)
			directory.appendCentral(header, localOffset: UInt32(archive.data.count))
			archive.appendLocal(header)
			archive.append(entry.data)
		}
		archive.append(directory.data)
		archive.appendEnd(
			entries: UInt16(entries.count),
			directorySize: UInt32(directorySize),
			directoryOffset: UInt32(directoryOffset)
		)
		return archive.data
	}

	static func read(_ archive: Data) throws -> [ZipEntry] {
		let archive = archive.startIndex == 0 ? archive : Data(archive)
		let directory = try centralDirectory(in: archive)
		var cursor = Cursor(archive, from: directory.span.lowerBound, to: directory.span.upperBound)
		let records = try (0 ..< directory.entries).map { _ in
			try record(from: &cursor, in: archive, before: directory.span.lowerBound)
		}
		guard cursor.position == directory.span.upperBound else { throw Failure.damaged(.inconsistent) }

		let spans = records.map(\.span).sorted { $0.lowerBound < $1.lowerBound }
		guard zip(spans, spans.dropFirst()).allSatisfy({ $0.upperBound <= $1.lowerBound }) else {
			throw Failure.damaged(.overlapping)
		}

		return try records.map { record in
			let data = archive.subdata(in: record.data)
			guard crc32(data) == record.header.crc else { throw Failure.damaged(.checksum) }
			return ZipEntry(name: record.name, data: data, modified: moment(time: record.header.time, date: record.header.date))
		}
	}

	static func crc32(_ data: Data) -> UInt32 {
		let table = crcTable
		return ~data.withUnsafeBytes { bytes in
			bytes.reduce(~UInt32.zero) { crc, byte in table[Int(UInt8(truncatingIfNeeded: crc) ^ byte)] ^ crc >> 8 }
		}
	}

	private static let crcTable: [UInt32] = (0 ... 255).map { index in
		(0 ..< 8).reduce(UInt32(index)) { crc, _ in crc & 1 == 1 ? 0xEDB8_8320 ^ crc >> 1 : crc >> 1 }
	}

	private static func centralDirectory(in archive: Data) throws -> (span: Range<Int>, entries: Int) {
		let last = archive.count - Layout.endRecord
		for start in stride(from: last, through: max(0, last - Limit.comment), by: -1) {
			var end = Cursor(archive, from: start, to: archive.count)
			guard try end.integer() == Signature.end else { continue }
			let disk: UInt16 = try end.integer()
			let directoryDisk: UInt16 = try end.integer()
			let entriesOnDisk: UInt16 = try end.integer()
			let entries: UInt16 = try end.integer()
			let size: UInt32 = try end.integer()
			let offset: UInt32 = try end.integer()
			let commentLength: UInt16 = try end.integer()
			guard start + Layout.endRecord + Int(commentLength) == archive.count else { continue }

			guard entries != .max, size != .max, offset != .max else { throw Failure.unsupported(.zip64) }
			guard disk == 0, directoryDisk == 0, entriesOnDisk == entries else { throw Failure.unsupported(.multipleDisks) }
			let directoryEnd = Int(offset) + Int(size)
			guard directoryEnd <= start else { throw Failure.damaged(.outOfBounds) }
			guard directoryEnd == start else {
				var locator = Cursor(archive, from: start - Layout.zip64Locator, to: start)
				throw (try? locator.integer()) == Signature.zip64Locator
					? Failure.unsupported(.zip64)
					: Failure.damaged(.inconsistent)
			}
			return (Int(offset) ..< directoryEnd, Int(entries))
		}
		throw archive.starts(with: Signature.localBytes) ? Failure.damaged(.truncated) : Failure.notAZip
	}

	private static func record(from directory: inout Cursor, in archive: Data, before directoryStart: Int) throws -> Record {
		guard try directory.integer() == Signature.central else { throw Failure.damaged(.inconsistent) }
		try directory.skip(2)
		let fields = try directory.header()
		let commentLength: UInt16 = try directory.integer()
		let disk: UInt16 = try directory.integer()
		try directory.skip(6)
		let localOffset: UInt32 = try directory.integer()
		var central = fields.header
		central.name = try directory.data(fields.nameLength)
		try directory.skip(fields.extraLength + Int(commentLength))

		try requireSupported(central, disk: disk, localOffset: localOffset)
		guard let name = String(validating: central.name, as: UTF8.self), isSafe(name) else { throw Failure.unsafeName }

		var cursor = Cursor(archive, from: Int(localOffset), to: directoryStart)
		guard try cursor.integer() == Signature.local else { throw Failure.damaged(.inconsistent) }
		let localFields = try cursor.header()
		var local = localFields.header
		local.name = try cursor.data(localFields.nameLength)
		try cursor.skip(localFields.extraLength)
		let data = try cursor.take(Int(central.compressedSize))
		guard local == central, central.compressedSize == central.size else { throw Failure.damaged(.inconsistent) }
		return Record(name: name, header: central, span: Int(localOffset) ..< data.upperBound, data: data)
	}

	private static func requireSupported(_ header: Header, disk: UInt16, localOffset: UInt32) throws {
		guard header.flags & Flag.encrypted == 0 else { throw Failure.unsupported(.encryption) }
		guard header.compressedSize != .max, header.size != .max, localOffset != .max, disk != .max else {
			throw Failure.unsupported(.zip64)
		}
		guard disk == 0 else { throw Failure.unsupported(.multipleDisks) }
		guard header.flags & Flag.dataDescriptor == 0 else { throw Failure.unsupported(.dataDescriptor) }
		guard header.method == 0 else { throw Failure.unsupported(.compression(method: header.method)) }
		let unknownFlags = header.flags & ~Flag.utf8
		guard unknownFlags == 0 else { throw Failure.unsupported(.unknownFlags(unknownFlags)) }
	}

	private static func encodedName(_ name: String) throws -> Data {
		guard isSafe(name) else { throw Failure.unsafeName }
		let bytes = Data(name.utf8)
		guard bytes.count <= Limit.name else { throw Failure.tooLarge }
		return bytes
	}

	private static func isSafe(_ name: String) -> Bool {
		let bytes = name.utf8
		guard !bytes.contains(0), !bytes.contains(UInt8(ascii: "\\")) else { return false }
		return bytes.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false).allSatisfy { component in
			!component.isEmpty && !component.elementsEqual(".".utf8) && !component.elementsEqual("..".utf8)
		}
	}

	private static let utc: Calendar = {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = .gmt
		return calendar
	}()

	private static func dosTimestamp(of moment: Date) -> (time: UInt16, date: UInt16) {
		let seconds = moment.timeIntervalSince1970
		let bounded = seconds >= DOSRange.earliest ? min(seconds, DOSRange.latest) : DOSRange.earliest
		let wholeSeconds = Date(timeIntervalSince1970: bounded.rounded(.down))
		let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: wholeSeconds)
		let year = (parts.year ?? 1980) - 1980
		let date = year << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1)
		let time = (parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2
		return (UInt16(time), UInt16(date))
	}

	private static func moment(time: UInt16, date: UInt16) -> Date {
		let parts = DateComponents(
			year: 1980 + Int(date >> 9), month: Int(date >> 5 & 0x0F), day: Int(date & 0x1F),
			hour: Int(time >> 11), minute: Int(time >> 5 & 0x3F), second: Int(time & 0x1F) * 2
		)
		return utc.date(from: parts) ?? Date(timeIntervalSince1970: DOSRange.earliest)
	}

	private enum Signature {
		static let local: UInt32 = 0x0403_4B50
		static let central: UInt32 = 0x0201_4B50
		static let end: UInt32 = 0x0605_4B50
		static let zip64Locator: UInt32 = 0x0706_4B50
		static let localBytes = Data([0x50, 0x4B, 0x03, 0x04])
	}

	private enum Flag {
		static let encrypted: UInt16 = 0x2041
		static let dataDescriptor: UInt16 = 0x0008
		static let utf8: UInt16 = 0x0800
	}

	private enum Layout {
		static let localHeader = 30
		static let centralHeader = 46
		static let endRecord = 22
		static let zip64Locator = 20
		static let versionNeeded: UInt16 = 20
		static let versionMadeByUnix: UInt16 = 0x0314
		static let regularFileAttributes: UInt32 = 0o100644 << 16
	}

	private enum Limit {
		static let entries = 0xFFFF
		static let size = 0xFFFF_FFFF
		static let name = 0xFFFF
		static let comment = 0xFFFF
	}

	private enum DOSRange {
		static let earliest: TimeInterval = 315_532_800
		static let latest: TimeInterval = 4_354_819_198
	}

	private struct Header: Equatable {
		var flags: UInt16
		var method: UInt16
		var time: UInt16
		var date: UInt16
		var crc: UInt32
		var compressedSize: UInt32
		var size: UInt32
		var name = Data()
	}

	private struct Record {
		let name: String
		let header: Header
		let span: Range<Int>
		let data: Range<Int>
	}

	private struct Output {
		private(set) var data: Data

		init(capacity: Int) {
			data = Data(capacity: capacity)
		}

		mutating func append(_ value: some FixedWidthInteger) {
			withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
		}

		mutating func append(_ bytes: Data) {
			data.append(bytes)
		}

		mutating func appendLocal(_ header: Header) {
			append(Signature.local)
			appendFields(of: header)
			append(header.name)
		}

		mutating func appendCentral(_ header: Header, localOffset: UInt32) {
			let commentLength: UInt16 = 0
			let startDisk: UInt16 = 0
			let internalAttributes: UInt16 = 0
			append(Signature.central)
			append(Layout.versionMadeByUnix)
			appendFields(of: header)
			append(commentLength)
			append(startDisk)
			append(internalAttributes)
			append(Layout.regularFileAttributes)
			append(localOffset)
			append(header.name)
		}

		mutating func appendEnd(entries: UInt16, directorySize: UInt32, directoryOffset: UInt32) {
			let disk: UInt16 = 0
			let commentLength: UInt16 = 0
			append(Signature.end)
			append(disk)
			append(disk)
			append(entries)
			append(entries)
			append(directorySize)
			append(directoryOffset)
			append(commentLength)
		}

		private mutating func appendFields(of header: Header) {
			let extraLength: UInt16 = 0
			append(Layout.versionNeeded)
			append(header.flags)
			append(header.method)
			append(header.time)
			append(header.date)
			append(header.crc)
			append(header.compressedSize)
			append(header.size)
			append(UInt16(header.name.count))
			append(extraLength)
		}
	}

	private struct Cursor {
		private let bytes: Data
		private let end: Int
		private(set) var position: Int

		init(_ bytes: Data, from start: Int, to end: Int) {
			self.bytes = bytes
			self.end = min(end, bytes.count)
			position = start
		}

		mutating func take(_ count: Int) throws -> Range<Int> {
			guard position >= 0, count >= 0, count <= end - position else { throw Failure.damaged(.outOfBounds) }
			defer { position += count }
			return position ..< position + count
		}

		mutating func skip(_ count: Int) throws {
			_ = try take(count)
		}

		mutating func data(_ count: Int) throws -> Data {
			let span = try take(count)
			return bytes.subdata(in: span)
		}

		mutating func integer<T: FixedWidthInteger>() throws -> T {
			let span = try take(MemoryLayout<T>.size)
			return T(littleEndian: bytes[span].withUnsafeBytes { $0.loadUnaligned(as: T.self) })
		}

		mutating func header() throws -> (header: Header, nameLength: Int, extraLength: Int) {
			try skip(2)
			let header = try Header(
				flags: integer(), method: integer(), time: integer(), date: integer(),
				crc: integer(), compressedSize: integer(), size: integer()
			)
			let nameLength: UInt16 = try integer()
			let extraLength: UInt16 = try integer()
			return (header, Int(nameLength), Int(extraLength))
		}
	}
}
