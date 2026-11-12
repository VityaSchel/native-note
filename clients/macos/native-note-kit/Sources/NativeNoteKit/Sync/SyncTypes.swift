import CryptoKit
import Foundation

nonisolated struct SyncSettings: Sendable {
	let server: URL
	let apiKey: SymmetricKey
	let contentKey: SymmetricKey
}

nonisolated struct SealedWrite: Sendable {
	let note: Note
	let write: Write
}

nonisolated struct PulledChange: Sendable {
	let content: Content
	let v: UInt32
	let writeId: Data
}

nonisolated struct Exchange: Sendable {
	var sent: [SealedWrite] = []
	var results: [WriteResult] = []
	var changes: [PulledChange] = []
	var nextSeq: UInt64 = 0
	var unacknowledged: [Data: SealedWrite] = [:]
	var pullMark: PullMark?
}

nonisolated struct PullMark: Equatable, Sendable {
	let blindedId: Data
	let v: UInt32
}

nonisolated enum Commit: Sendable {
	case settleLastVersion
	case exchange(Exchange)
}

public enum SyncProblem: Equatable, Sendable {
	case serverBehind
	case unverifiableChange
	case tooLarge(UUID)
}

nonisolated struct Applied: Sendable {
	var changed: [UUID: Note] = [:]
	var copies: [UUID: UUID] = [:]
	var pulled: Set<UUID> = []
	var problems: [SyncProblem] = []

	mutating func merge(_ other: Applied) {
		changed.merge(other.changed) { $1 }
		copies.merge(other.copies) { $1 }
		pulled.formUnion(other.pulled)
		problems += other.problems
	}
}
