import Foundation
import Testing

enum ProofSource {
	static func flaw(ofSwiftTest name: String, in source: String) -> String? {
		flaw(of: "func \(name)(", marker: "@Test", disabling: ".disabled(", expectations: ["#expect(", "#require("], in: source)
	}

	static func flaw(ofRustTest name: String, in source: String) -> String? {
		flaw(of: "fn \(name)(", marker: "#[test]", disabling: "#[ignore", expectations: ["assert!(", "assert_eq!(", "assert_ne!("], in: source)
	}

	private static func flaw(of declaration: String, marker: String, disabling: String, expectations: [String], in source: String) -> String? {
		let lines = source.components(separatedBy: "\n")
		guard let start = lines.firstIndex(where: { $0.contains(declaration) }) else { return "has no \(declaration)" }
		let indentation = String(lines[start].prefix { $0 == "\t" })
		let closing = indentation + "}"
		let precedingLines = lines[..<start].reversed().prefix { !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0 != closing }
		let attributes = precedingLines.reversed() + [lines[start].components(separatedBy: declaration)[0]]
		guard attributes.contains(where: { $0.contains(marker) }) else { return "is not marked \(marker)" }
		guard !attributes.contains(where: { $0.contains(disabling) }) else { return "is disabled" }
		let isOneLine = lines[start].hasSuffix("}")
		let body = isOneLine ? [String(lines[start].drop { $0 != "{" })] : Array(lines[(start + 1)...].prefix { $0 != closing })
		let code = body.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
		guard code.contains(where: { line in expectations.contains { line.contains($0) } }) else { return "expects nothing" }
		return nil
	}
}

struct ThreatModelCoverageTests {
	private struct Proof {
		enum Kind {
			case swiftTest
			case rustTest
			case text
		}

		let file: String
		let name: String
		let kind: Kind

		static func swift(_ file: String, _ name: String) -> Proof {
			Proof(file: "clients/macos/native-note-kit/Tests/NativeNoteKitTests/\(file).swift", name: name, kind: .swiftTest)
		}

		static func rust(_ file: String, _ name: String) -> Proof {
			Proof(file: file, name: name, kind: .rustTest)
		}

		static func text(_ file: String, _ name: String) -> Proof {
			Proof(file: file, name: name, kind: .text)
		}

		func flaw(in source: String) -> String? {
			switch kind {
			case .swiftTest: ProofSource.flaw(ofSwiftTest: name, in: source)
			case .rustTest: ProofSource.flaw(ofRustTest: name, in: source)
			case .text: source.contains(name) ? nil : "has no \(name)"
			}
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
		"Argon2 and SQLCipher": [.swift("ThreatModel/BoundaryTests", "sqlCipherUsesCommonCryptoAndBothCLibrariesArePinned")],
		"Hand-rolled HTTP parser": [
			.rust("server/native-note-core/src/http/tests.rs", "bad_framing_is_a_bad_request"),
			.rust("server/native-note-core/src/http/tests.rs", "at_most_one_hundred_headers_are_accepted"),
			.text("server/native-note-core/fuzz/fuzz_targets/http.rs", "fuzz_target!"),
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

	@Test func everyNamedProofIsATestThatRunsAndExpectsSomething() throws {
		for (claim, proofs) in Self.proofs {
			#expect(!proofs.isEmpty, "\(claim)")
			for proof in proofs {
				let source = try String(contentsOf: Self.repository.appending(path: proof.file), encoding: .utf8)
				let flaw = proof.flaw(in: source)
				#expect(flaw == nil, "\(claim): \(proof.name) in \(proof.file) \(flaw ?? "")")
			}
		}
	}

	@Test(arguments: [
		("\t@Test func proof() async throws {\n\t\tlet opened = try open()\n\t\t#expect(opened)\n\t}", nil),
		("\t@Test(arguments: [\n\t\t1,\n\t])\n\tfunc proof(seed: Int) throws {\n\t\ttry #require(seed > 0)\n\t}", nil),
		("\t@Test func proof() { #expect(true) }", nil),
		("\t@Test func another() {\n\t\t#expect(true)\n\t}", "has no func proof("),
		("\tprivate func proof() {\n\t\t#expect(true)\n\t}", "is not marked @Test"),
		("\t@Test func other() {\n\t\t#expect(true)\n\t}\n\tfunc proof() {\n\t\t#expect(true)\n\t}", "is not marked @Test"),
		("\t@Test(.disabled(\"later\")) func proof() {\n\t\t#expect(true)\n\t}", "is disabled"),
		("\t@Test func proof() async throws {\n\t\t_ = try open()\n\t}", "expects nothing"),
		("\t@Test func proof() {\n\t\t// #expect(opened)\n\t}", "expects nothing"),
		("\t@Test func proof() {\n\t\tsetUp()\n\t}\n\n\t@Test func next() {\n\t\t#expect(true)\n\t}", "expects nothing"),
	] as [(String, String?)])
	func aSwiftProofCountsOnlyAsARunningTestWithAnExpectation(source: String, flaw: String?) {
		#expect(ProofSource.flaw(ofSwiftTest: "proof", in: source) == flaw)
	}

	@Test(arguments: [
		("#[test]\nfn proof() {\n\tassert_eq!(status(), 413);\n}", nil),
		("fn proof() {\n\tassert!(true);\n}", "is not marked #[test]"),
		("#[test]\n#[ignore]\nfn proof() {\n\tassert!(true);\n}", "is disabled"),
		("#[test]\nfn proof() {\n\tlet _ = status();\n}\n\n#[test]\nfn next() {\n\tassert!(true);\n}", "expects nothing"),
		("#[test]\nfn other() {\n\tassert!(true);\n}", "has no fn proof("),
	] as [(String, String?)])
	func aRustProofCountsOnlyAsARunningTestWithAnAssertion(source: String, flaw: String?) {
		#expect(ProofSource.flaw(ofRustTest: "proof", in: source) == flaw)
	}
}
