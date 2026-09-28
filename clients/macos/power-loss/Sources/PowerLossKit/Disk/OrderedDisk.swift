import Darwin
import Foundation
import Synchronization

public enum DiskError: Error, Equatable, Sendable {
	case poweredOff
	case outOfBounds
	case io(errno: Int32)
}

public struct TornWrite: Codable, Equatable, Sendable {
	public let offset: Int
	public let length: Int
	public let kept: Int
	public let zeroes: Bool
	public let millisecondsAfterCut: Int

	public init(offset: Int, length: Int, kept: Int, zeroes: Bool = false, millisecondsAfterCut: Int = 0) {
		self.offset = offset
		self.length = length
		self.kept = kept
		self.zeroes = zeroes
		self.millisecondsAfterCut = millisecondsAfterCut
	}
}

public struct CutReport: Codable, Equatable, Sendable {
	public let torn: TornWrite?
	public let dropped: DiskActivity

	public init(torn: TornWrite?, dropped: DiskActivity) {
		self.torn = torn
		self.dropped = dropped
	}
}

public final class OrderedDisk: Sendable {
	private enum Power {
		case on
		case tearingNextChange(seed: UInt64, cutAt: ContinuousClock.Instant)
		case off
	}

	private struct State {
		var power = Power.on
		var torn: TornWrite?
	}

	private enum Change {
		case bytes([UInt8])
		case zeros(Int)

		var length: Int {
			switch self {
			case .bytes(let bytes): bytes.count
			case .zeros(let count): count
			}
		}

		var isZeros: Bool {
			if case .zeros = self { true } else { false }
		}

		func prefix(_ count: Int) -> Change {
			switch self {
			case .bytes(let bytes): .bytes(Array(bytes.prefix(count)))
			case .zeros: .zeros(count)
			}
		}
	}

	public let size: Int
	public let sectorSize: Int
	private let descriptor: Int32
	private let state = Mutex(State())

	private static let holeAlignment = 4096
	private static let zeroChunk = 1 << 20

	public init(backing url: URL, sectorSize: Int = 4096) throws {
		precondition(sectorSize > 0)
		let descriptor = open(url.path, O_RDWR | O_CLOEXEC)
		guard descriptor >= 0 else { throw DiskError.io(errno: errno) }
		var status = stat()
		guard fstat(descriptor, &status) == 0 else {
			let failure = DiskError.io(errno: errno)
			close(descriptor)
			throw failure
		}
		self.descriptor = descriptor
		self.size = Int(status.st_size)
		self.sectorSize = sectorSize
	}

	deinit {
		close(descriptor)
	}

	public var isPoweredOn: Bool {
		state.withLock { state in
			if case .on = state.power { true } else { false }
		}
	}

	public var tornWrite: TornWrite? {
		state.withLock { $0.torn }
	}

	public func read(at offset: Int, count: Int) throws -> [UInt8] {
		try state.withLock { state in
			try requireInBounds(offset, count)
			guard case .on = state.power else { throw DiskError.poweredOff }
			return try readFile(at: offset, count: count)
		}
	}

	public func write(_ bytes: [UInt8], at offset: Int) throws {
		try apply(.bytes(bytes), at: offset)
	}

	public func zero(at offset: Int, count: Int) throws {
		try apply(.zeros(count), at: offset)
	}

	public func cutPower(tearingWith seed: UInt64?) {
		state.withLock { state in
			guard case .on = state.power else { return }
			state.power = seed.map { .tearingNextChange(seed: $0, cutAt: .now) } ?? .off
			state.torn = nil
		}
	}

	public func restorePower() {
		state.withLock { $0.power = .on }
	}

	public static func tearPoint(offset: Int, length: Int, sectorSize: Int, seed: UInt64) -> Int {
		guard length > 0 else { return 0 }
		let firstSector = offset / sectorSize
		let innerBoundaries = (offset + length - 1) / sectorSize - firstSector
		var generator = SplitMix64(seed: seed)
		let choice = Int(generator.next() % UInt64(innerBoundaries + 2))
		switch choice {
		case 0: return 0
		case innerBoundaries + 1: return length
		default: return (firstSector + choice) * sectorSize - offset
		}
	}

	private func apply(_ change: Change, at offset: Int) throws {
		try state.withLock { state in
			try requireInBounds(offset, change.length)
			switch state.power {
			case .on:
				try store(change, at: offset)
			case .off:
				throw DiskError.poweredOff
			case .tearingNextChange(let seed, let cutAt):
				state.power = .off
				let kept = Self.tearPoint(offset: offset, length: change.length, sectorSize: sectorSize, seed: seed)
				let afterCut = (ContinuousClock.now - cutAt).milliseconds
				state.torn = TornWrite(offset: offset, length: change.length, kept: kept, zeroes: change.isZeros, millisecondsAfterCut: afterCut)
				try store(change.prefix(kept), at: offset)
				throw DiskError.poweredOff
			}
		}
	}

	private func requireInBounds(_ offset: Int, _ count: Int) throws {
		guard offset >= 0, count >= 0, offset <= size, count <= size - offset else { throw DiskError.outOfBounds }
	}

	private func store(_ change: Change, at offset: Int) throws {
		guard change.length > 0 else { return }
		switch change {
		case .bytes(let bytes):
			try bytes.withUnsafeBytes { try writeFile($0, at: offset) }
		case .zeros(let count):
			try zeroFile(offset ..< offset + count)
		}
	}

	private func readFile(at offset: Int, count: Int) throws -> [UInt8] {
		var bytes = [UInt8](repeating: 0, count: count)
		var done = 0
		while done < count {
			let result = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress! + done, count - done, off_t(offset + done)) }
			if result > 0 {
				done += result
			} else if result == 0 {
				break
			} else if errno != EINTR {
				throw DiskError.io(errno: errno)
			}
		}
		return bytes
	}

	private func writeFile(_ bytes: UnsafeRawBufferPointer, at offset: Int) throws {
		var done = 0
		while done < bytes.count {
			let result = pwrite(descriptor, bytes.baseAddress! + done, bytes.count - done, off_t(offset + done))
			if result > 0 {
				done += result
			} else if result < 0, errno == EINTR {
				continue
			} else {
				throw DiskError.io(errno: result < 0 ? errno : EIO)
			}
		}
	}

	private func zeroFile(_ span: Range<Int>) throws {
		let alignment = Self.holeAlignment
		let holeStart = (span.lowerBound + alignment - 1) / alignment * alignment
		let holeEnd = span.upperBound / alignment * alignment
		if holeStart < holeEnd, punchHole(holeStart ..< holeEnd) {
			try writeZeros(span.lowerBound ..< holeStart)
			try writeZeros(holeEnd ..< span.upperBound)
		} else {
			try writeZeros(span)
		}
	}

	private func punchHole(_ range: Range<Int>) -> Bool {
		var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(range.lowerBound), fp_length: off_t(range.count))
		return fcntl(descriptor, F_PUNCHHOLE, &hole) == 0
	}

	private func writeZeros(_ range: Range<Int>) throws {
		let zeros = [UInt8](repeating: 0, count: min(range.count, Self.zeroChunk))
		var start = range.lowerBound
		while start < range.upperBound {
			let count = min(zeros.count, range.upperBound - start)
			try zeros.withUnsafeBytes { try writeFile(UnsafeRawBufferPointer(rebasing: $0.prefix(count)), at: start) }
			start += count
		}
	}
}
