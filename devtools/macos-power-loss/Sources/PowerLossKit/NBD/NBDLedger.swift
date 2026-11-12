import Synchronization

final class NBDLedger: Sendable {
	private struct State {
		var activity = DiskActivity()
		var dropped = DiskActivity()
	}

	private let state = Mutex(State())

	var activity: DiskActivity {
		state.withLock { $0.activity }
	}

	var dropped: DiskActivity {
		state.withLock { $0.dropped }
	}

	func served(_ command: NBD.Command, flags: UInt16) {
		state.withLock { Self.count(command, flags: flags, in: &$0.activity) }
	}

	func dropped(_ command: NBD.Command?, flags: UInt16) {
		state.withLock { Self.count(command, flags: flags, in: &$0.dropped) }
	}

	func refused(_ command: NBD.Command?) {
		state.withLock { state in
			if command == nil {
				state.activity.unknown += 1
			} else {
				state.activity.rejected += 1
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
