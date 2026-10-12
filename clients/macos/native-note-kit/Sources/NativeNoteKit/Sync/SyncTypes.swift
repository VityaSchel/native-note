import CryptoKit
import Foundation

nonisolated struct SyncSettings: Sendable {
	let server: URL
	let apiKey: SymmetricKey
	let contentKey: SymmetricKey
}

/// A write as sealed for a push, beside the note as it stood when sealed.
nonisolated struct SealedWrite: Sendable {
	let note: Note
	let write: Write
}

/// A pulled change that decrypted and whose ID re-derived its `blindedId`.
nonisolated struct PulledChange: Sendable {
	let content: Content
	let v: UInt32
	let writeId: Data
}

/// One verified sync response, ready to apply in one transaction.
nonisolated struct Exchange: Sendable {
	var sent: [SealedWrite] = []
	var results: [WriteResult] = []
	var changes: [PulledChange] = []
	var nextSeq: UInt64 = 0
	/// Writes whose responses were lost, by `writeId`; a pulled change carrying one is that write stored.
	var unacknowledged: [Data: SealedWrite] = [:]
}

/// What a sync commits in one transaction, under the caller's coordination with unsaved edits.
nonisolated enum Commit: Sendable {
	case settleLastVersion
	case exchange(Exchange)
}

public enum SyncProblem: Equatable, Sendable {
	/// The server holds less than this device has seen, as after a restore from an old backup.
	case serverBehind
	case unverifiableChange
	case tooLarge(UUID)
}

nonisolated struct Applied: Sendable {
	/// Rows as they stand after the transaction, conflict copies included.
	var changed: [UUID: Note] = [:]
	/// Each original whose unpushed text moved to a copy, mapped to that copy.
	var copies: [UUID: UUID] = [:]
	/// Notes whose text a pull replaced.
	var pulled: Set<UUID> = []
	var problems: [SyncProblem] = []

	mutating func merge(_ other: Applied) {
		changed.merge(other.changed) { $1 }
		copies.merge(other.copies) { $1 }
		pulled.formUnion(other.pulled)
		problems += other.problems
	}
}
