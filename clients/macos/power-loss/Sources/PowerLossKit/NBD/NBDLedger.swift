import Synchronization

public struct NBDRejection: Equatable, Sendable, CustomStringConvertible {
	public let type: UInt16
	public let flags: UInt16
	public let offset: UInt64
	public let length: UInt32
	public let error: UInt32
	public let reason: String

	public var isUnknownCommand: Bool {
		NBD.Command(rawValue: type) == nil
	}

	public var description: String {
		let command = NBD.Command(rawValue: type).map(\.name) ?? "unknown command \(type)"
		return "\(command) flags \(NBD.CommandFlag.describe(flags)) offset \(offset) length \(length): \(reason), answered \(NBD.Failure(rawValue: error)?.name ?? "error \(error)")"
	}
}

final class NBDLedger: Sendable {
	static let keptRejections = 256

	private struct State {
		var activity = DiskActivity()
		var dropped = DiskActivity()
		var rejections: [NBDRejection] = []
	}

	private let state = Mutex(State())

	var activity: DiskActivity {
		state.withLock { $0.activity }
	}

	var dropped: DiskActivity {
		state.withLock { $0.dropped }
	}

	var rejections: [NBDRejection] {
		state.withLock { $0.rejections }
	}

	func served(_ command: NBD.Command, flags: UInt16) {
		state.withLock { Self.count(command, flags: flags, in: &$0.activity) }
	}

	func dropped(_ command: NBD.Command?, flags: UInt16) {
		state.withLock { Self.count(command, flags: flags, in: &$0.dropped) }
	}

	func refused(_ rejection: NBDRejection) {
		state.withLock { state in
			if rejection.isUnknownCommand {
				state.activity.unknown += 1
			} else {
				state.activity.rejected += 1
			}
			if state.rejections.count < Self.keptRejections {
				state.rejections.append(rejection)
			}
		}
	}

	private static func count(_ command: NBD.Command?, flags: UInt16, in activity: inout DiskActivity) {
		let forced = flags & NBD.CommandFlag.forceUnitAccess != 0
		switch command {
		case .read:
			activity.reads += 1
		case .write:
			activity.writes += 1
			if forced { activity.forcedWrites += 1 }
		case .flush:
			activity.flushes += 1
		case .trim:
			activity.trims += 1
			if forced { activity.forcedWrites += 1 }
		case .writeZeroes:
			activity.writeZeroes += 1
			if forced { activity.forcedWrites += 1 }
		case .cache:
			activity.cache += 1
		case .disconnect:
			break
		case nil:
			activity.unknown += 1
		}
	}
}
