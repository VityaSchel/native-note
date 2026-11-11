import Foundation
import Testing

/// Every actor, out-of-scope item and documented risk in docs/ARCHITECTURE.md § Threat model names the tests that prove it,
/// non-goals included, so a claim added to the threat model fails here until a test backs it.
struct ThreatModelCoverageTests {
	private struct Proof {
		let file: String
		let needle: String

		static func swift(_ file: String, _ name: String) -> Proof {
			Proof(file: "clients/macos/native-note-kit/Tests/NativeNoteKitTests/\(file).swift", needle: "func \(name)(")
		}

		static func rust(_ file: String, _ name: String) -> Proof {
			Proof(file: file, needle: "fn \(name)(")
		}
	}

	private static let repository = URL(filePath: #filePath).appending(path: "../../../../../../..").standardized

	private static let lockingDrops = Proof.swift("ThreatModel/BoundaryTests", "lockingDropsWhatTheUnlockedLibraryHeld")
	private static let rightPasswordOpens = Proof.swift("Unlock/UnlockTests", "opensWithTheRightPasswordAndRefusesTheWrong")
	private static let wire = Proof.swift("ThreatModel/ServerViewTests", "everyEnvelopeOnTheWireIsBucketSizedAndHoldsNothingInTheClear")
	private static let headers = Proof.swift("Sync/TransportHeaderTests", "aRequestCarriesOnlyFixedHeadersTheSameOnEveryMac")
	private static let forged = Proof.swift("ThreatModel/APIKeyHolderTests", "aStolenAPIKeyForgesWritesTheServerKeepsButNoClientApplies")

	private static let proofs: [String: [Proof]] = [
		"Unlocked device, user present": [lockingDrops, rightPasswordOpens],
		"Locked or powered-off device": [
			.swift("EndToEnd/LibraryEndToEndTests+AtRest", "aLockedLibraryIsIndistinguishableFromRandomOnDisk"),
			.swift("ThreatModel/BoundaryTests", "aDeletedNoteLeavesNoPlaintextOnDisk"),
			lockingDrops,
		],
		"Sync server": [
			.swift("ThreatModel/ServerViewTests", "theServerStoresNoNoteTextIdentityOrKey"),
			.swift("Sync/SyncVerificationTests", "aChangeWhoseTextNamesAnotherNoteIsReportedAndNotApplied"),
			forged,
			.rust("server/native-note-core/tests/suite/sync.rs", "the_sync_vector_steps_run_in_order_against_one_server_and_the_replayed_step_conflicts"),
		],
		"Reverse proxy": [wire, headers],
		"Network": [wire, headers],
		"Code execution as the user on an unlocked machine": [lockingDrops],
		"Compromise of a device holding the content key": [.swift("ThreatModel/BoundaryTests", "theContentAndAPIKeysAloneReadEveryNote")],
		"Traffic analysis over plain HTTP": [wire, .swift("Sync/PayloadLengthTests", "aLongerNoteGrowsOnlyByWholeBlocks")],
		"Malicious server withholding notes": [.swift("ThreatModel/BoundaryTests", "aServerWithholdingAChangeGoesUnnoticed")],
		"Secure erasure of deleted content": [.swift("ThreatModel/BoundaryTests", "aDeletedNoteLeavesNoPlaintextOnDisk")],
		"Loss of the mnemonic and every device": [.swift("ThreatModel/BoundaryTests", "withoutThePhraseOrADeviceTheServersNotesStaySealed")],
		"Denial of service": [
			.rust("server/native-note-server/tests/suite/http.rs", "an_oversized_body_gets_413_before_any_of_it_is_sent"),
			.rust("server/native-note-server/tests/suite/http.rs", "a_stalled_client_is_closed_at_the_read_timeout_and_a_trickling_one_at_the_deadline"),
		],
		"Coercion": [rightPasswordOpens, .swift("EndToEnd/RestoreEndToEndTests", "aWipedMacRestoresEveryNoteFromThePhraseAndEditsFlowBothWays")],
		"No forward secrecy for metadata": [.swift("ThreatModel/ServerViewTests", "aLeakedAPIKeyOpensCapturedEnvelopesToMetadataButNotToNotes")],
		"Argon2 and SQLCipher": [.swift("ThreatModel/BoundaryTests", "sqlCipherUsesCommonCryptoAndBothCLibrariesArePinnedToCommits")],
		"Hand-rolled HTTP parser": [
			.rust("server/native-note-core/src/http/tests.rs", "bad_framing_is_a_bad_request"),
			.rust("server/native-note-core/src/http/tests.rs", "at_most_one_hundred_headers_are_accepted"),
			Proof(file: "server/native-note-core/fuzz/fuzz_targets/http.rs", needle: "fuzz_target!"),
		],
		"Plaintext `v` leaks per-note edit counts": [.swift("ThreatModel/ServerViewTests", "theServerSeesEachNotesVersionCountAndNothingElseOfIt")],
		"Payload length leaks note size in 4 KiB steps": [
			.swift("Sync/PayloadLengthTests", "aDeletionLooksLikeAShortNote"),
			.swift("Sync/PayloadLengthTests", "aLongerNoteGrowsOnlyByWholeBlocks"),
		],
		"An API-key holder can destroy the recovery path": [.swift("ThreatModel/APIKeyHolderTests", "anAPIKeyHolderCanDestroyTheRecoveryPathButCannotPlantAKey")],
		"Server data-directory compromise leaks the API key": [forged],
		"No per-device revocation": [.swift("ThreatModel/APIKeyHolderTests", "replacingTheServersAPIKeyShutsOutEveryHolderOfTheOldOne"), headers],
		"A short password or pin without hardware binding": [.swift("ThreatModel/BoundaryTests", "aLibraryWithoutHardwareBindingCanBeGuessedFromItsFilesAlone")],
		"No in-app unlock attempt limiting": [.swift("ThreatModel/BoundaryTests", "anyNumberOfWrongPasswordsLeavesTheRightOneWorking")],
		"Hardware binding does not add per-guess cost": [
			.swift("Unlock/UnlockTests", "aDifferentDeviceKeyProducesADifferentKey"),
			.swift("ThreatModel/BoundaryTests", "withTheMachineIdReadOnceGuessingCostsOnlyArgon2"),
		],
		"The content key never rotates": [
			.swift("Model/AppModelSyncTests", "rotationMovesThePinAndAStalePinAdoptsTheCurrentPhraseBeforeRotatingAgain"),
			.swift("ThreatModel/BoundaryTests", "aBlobFromBeforeAPhraseChangeStillOpensWithTheOldWords"),
			.swift("ThreatModel/APIKeyHolderTests", "anAPIKeyHolderCanDestroyTheRecoveryPathButCannotPlantAKey"),
		],
	]

	private static func claims() throws -> [String] {
		let architecture = try String(contentsOf: repository.appending(path: "docs/ARCHITECTURE.md"), encoding: .utf8)
		let section = try #require(architecture.components(separatedBy: "\n## Threat model\n").dropFirst().first?.components(separatedBy: "\n## ").first)
		return section.split(separator: "\n").compactMap { line -> String? in
			if line.hasPrefix("| "), !line.hasPrefix("| Actor"), !line.hasPrefix("| ---") {
				return line.split(separator: "|").first.map { $0.trimmingCharacters(in: .whitespaces) }
			}
			guard line.hasPrefix("- ") else { return nil }
			let entry = line.dropFirst(2)
			if entry.hasPrefix("**"), let end = entry.dropFirst(2).range(of: "**") {
				let lead = entry.dropFirst(2)[..<end.lowerBound]
				return String(lead.hasSuffix(".") ? lead.dropLast() : lead)
			}
			return String(entry.components(separatedBy: " — ").first ?? String(entry))
		}
	}

	@Test func everyThreatModelClaimNamesTestsThatProveIt() throws {
		let claims = try Self.claims()

		#expect(claims.count == Self.proofs.count)
		#expect(Set(claims) == Set(Self.proofs.keys), "unproven: \(Set(claims).subtracting(Self.proofs.keys)); stale: \(Set(Self.proofs.keys).subtracting(claims))")
	}

	@Test func everyNamedProofExists() throws {
		for (claim, proofs) in Self.proofs {
			#expect(!proofs.isEmpty, "\(claim)")
			for proof in proofs {
				let source = try String(contentsOf: Self.repository.appending(path: proof.file), encoding: .utf8)
				#expect(source.contains(proof.needle), "\(claim): \(proof.file) has no \(proof.needle)")
			}
		}
	}
}
