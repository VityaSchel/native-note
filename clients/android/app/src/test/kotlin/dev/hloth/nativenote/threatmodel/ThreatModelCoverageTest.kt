package dev.hloth.nativenote.threatmodel

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

object ProofSource {
	fun flawOfKotlinTest(name: String, source: String) =
		flaw("fun $name(", marker = "@Test", disabling = "@Ignore", expectations = listOf("assert", "check(", "fail("), source)

	fun flawOfSwiftTest(name: String, source: String) =
		flaw("func $name(", marker = "@Test", disabling = ".disabled(", expectations = listOf("#expect(", "#require("), source)

	fun flawOfRustTest(name: String, source: String) =
		flaw("fn $name(", marker = "#[test]", disabling = "#[ignore", expectations = listOf("assert!(", "assert_eq!(", "assert_ne!("), source)

	private fun flaw(declaration: String, marker: String, disabling: String, expectations: List<String>, source: String): String? {
		val lines = source.split("\n")
		val start = lines.indexOfFirst { declaration in it }
		if (start < 0) return "has no $declaration"
		val indentation = lines[start].takeWhile { it == '\t' }
		val closing = "$indentation}"
		val attributes = lines.subList(0, start).asReversed().takeWhile { it.isNotBlank() && it != closing }.reversed() + lines[start].substringBefore(declaration)
		if (attributes.none { marker in it }) return "is not marked $marker"
		if (attributes.any { disabling in it }) return "is disabled"
		val opening = lines[start].trimEnd()
		val body = if (opening.endsWith("{") || opening.endsWith("->")) lines.drop(start + 1).takeWhile { it != closing } else listOf(opening.substringAfter(declaration))
		val code = body.filterNot { it.trim().startsWith("//") }
		if (code.none { line -> expectations.any { it in line } }) return "expects nothing"
		return null
	}
}

class ThreatModelCoverageTest {
	private class Proof(val file: String, val name: String, private val kind: Kind) {
		enum class Kind { Kotlin, Swift, Rust, Text }

		fun flaw(source: String): String? = when (kind) {
			Kind.Kotlin -> ProofSource.flawOfKotlinTest(name, source)
			Kind.Swift -> ProofSource.flawOfSwiftTest(name, source)
			Kind.Rust -> ProofSource.flawOfRustTest(name, source)
			Kind.Text -> if (name in source) null else "has no $name"
		}

		companion object {
			fun device(file: String, name: String) = Proof("clients/android/app/src/androidTest/kotlin/dev/hloth/nativenote/$file.kt", name, Kind.Kotlin)

			fun shared(file: String, name: String) = Proof("clients/android/app/src/sharedTest/kotlin/dev/hloth/nativenote/$file.kt", name, Kind.Kotlin)

			fun jvm(file: String, name: String) = Proof("clients/android/app/src/test/kotlin/dev/hloth/nativenote/$file.kt", name, Kind.Kotlin)

			fun macOS(file: String, name: String) = Proof("clients/macos/native-note-kit/Tests/NativeNoteKitTests/$file.swift", name, Kind.Swift)

			fun rust(file: String, name: String) = Proof(file, name, Kind.Rust)

			fun text(file: String, name: String) = Proof(file, name, Kind.Text)
		}
	}

	private val repository = File("../../..").canonicalFile

	private val lockingDrops = Proof.device("threatmodel/BoundaryTest", "lockingDropsWhatTheUnlockedLibraryHeld")
	private val rightPasswordOpens = Proof.device("model/AppModelTest", "aRelaunchFindsTheLibraryLockedAndOnlyThePasswordOpensIt")
	private val wire = Proof.device("threatmodel/ServerViewTest", "everyEnvelopeOnTheWireIsBucketSizedAndHoldsNothingInTheClear")
	private val headers = Proof.device("threatmodel/TransportHeaderTest", "aRequestCarriesOnlyFixedHeadersTheSameOnEveryPhone")
	private val forged = Proof.device("threatmodel/ServerViewTest", "aStolenAPIKeyForgesWritesThatNoPhoneApplies")
	private val recoveryBlobs = Proof.shared("conformance/RecoveryVectorTest", "recoveryBlobsSealExactlyAndOpenOnlyToAThirtyTwoByteKeyUnderTheirOwnRecoveryKey")

	private val proofs: Map<String, List<Proof>> = mapOf(
		"Unlocked device, user present" to listOf(lockingDrops, rightPasswordOpens),
		"Locked or powered-off device" to listOf(
			Proof.device("model/LibraryAtRestTest", "aLockedLibraryOnDiskIsIndistinguishableFromRandom"),
			Proof.device("threatmodel/BoundaryTest", "aDeletedNoteLeavesNoPlaintextOnDisk"),
			lockingDrops,
		),
		"Sync server" to listOf(
			Proof.macOS("ThreatModel/ServerViewTests", "theServerStoresNoNoteTextIdentityOrKey"),
			Proof.device("sync/ServerSyncTest", "anotherLibrarysChangesAreSkippedAsUnreadable"),
			forged,
			Proof.rust("server/native-note-core/tests/suite/sync.rs", "the_sync_vector_steps_run_in_order_against_one_server_and_the_replayed_step_conflicts"),
		),
		"Reverse proxy" to listOf(wire, headers),
		"Network" to listOf(wire, headers, Proof.device("threatmodel/TransportHeaderTest", "aRedirectIsReportedNotFollowed")),
		"Code execution as the user on an unlocked machine" to listOf(lockingDrops),
		"Compromise of a device holding the content key" to listOf(Proof.device("threatmodel/ServerViewTest", "theContentAndAPIKeysAloneReadEveryNote")),
		"Traffic analysis over plain HTTP" to listOf(wire, Proof.shared("threatmodel/PayloadLengthTest", "aLongerNoteGrowsOnlyByWholeBlocks")),
		"Malicious server withholding notes" to listOf(Proof.macOS("ThreatModel/BoundaryTests", "aServerWithholdingAChangeGoesUnnoticed")),
		"Secure erasure of deleted content" to listOf(Proof.device("threatmodel/BoundaryTest", "aDeletedNoteLeavesNoPlaintextOnDisk")),
		"Loss of the mnemonic and every device" to listOf(
			Proof.macOS("ThreatModel/BoundaryTests", "withoutThePhraseOrADeviceTheServersNotesStaySealed"),
			Proof.device("sync/RecoveryServerTest", "afterRotatingOnlyTheNewWordsJoin"),
			recoveryBlobs,
		),
		"Denial of service" to listOf(
			Proof.rust("server/native-note-server/tests/suite/http.rs", "an_oversized_body_gets_413_before_any_of_it_is_sent"),
			Proof.rust("server/native-note-server/tests/suite/http.rs", "a_stalled_client_is_closed_at_the_read_timeout_and_a_trickling_one_at_the_deadline"),
		),
		"Coercion" to listOf(rightPasswordOpens, Proof.device("sync/RecoveryServerTest", "aWipedPhoneRestoresEveryNoteFromTheWordsAndTheApiKey")),
		"No forward secrecy for metadata" to listOf(Proof.device("threatmodel/ServerViewTest", "aLeakedAPIKeyOpensCapturedEnvelopesToMetadataButNotToNotes")),
		"Argon2 and SQLCipher" to listOf(
			Proof.device("storage/SQLCipherBuildTest", "isSQLCipher4_17OnLibTomCrypt"),
			Proof.jvm("threatmodel/NativePinsTest", "everyCLibraryIsBuiltFromAPinnedRevision"),
		),
		"Hand-rolled HTTP parser" to listOf(
			Proof.rust("server/native-note-core/src/http/tests.rs", "bad_framing_is_a_bad_request"),
			Proof.rust("server/native-note-core/src/http/tests.rs", "at_most_one_hundred_headers_are_accepted"),
			Proof.text("server/native-note-core/fuzz/fuzz_targets/http.rs", "fuzz_target!"),
		),
		"Plaintext `v` leaks per-note edit counts" to listOf(Proof.device("threatmodel/ServerViewTest", "theServerSeesEachNotesVersionCountAndNothingElseOfIt")),
		"Payload length leaks note size in 4 KiB steps" to listOf(
			Proof.shared("threatmodel/PayloadLengthTest", "aDeletionLooksLikeAShortNote"),
			Proof.shared("threatmodel/PayloadLengthTest", "aLongerNoteGrowsOnlyByWholeBlocks"),
		),
		"An API-key holder can destroy the recovery path" to listOf(
			Proof.macOS("ThreatModel/APIKeyHolderTests", "anAPIKeyHolderCanDestroyTheRecoveryPathButCannotPlantAKey"),
			recoveryBlobs,
		),
		"Server data-directory compromise leaks the API key" to listOf(forged),
		"No per-device revocation" to listOf(
			Proof.macOS("ThreatModel/APIKeyHolderTests", "replacingTheServersAPIKeyShutsOutEveryHolderOfTheOldOne"),
			Proof.device("sync/ServerSyncTest", "aWrongApiKeyIsRefused"),
			headers,
		),
		"A short password or pin without hardware binding" to listOf(Proof.device("threatmodel/BoundaryTest", "aLibraryWithoutHardwareBindingCanBeGuessedFromItsFilesAlone")),
		"No in-app unlock attempt limiting" to listOf(Proof.device("threatmodel/BoundaryTest", "anyNumberOfWrongPasswordsLeavesTheRightOneWorking")),
		"Hardware binding does not add per-guess cost" to listOf(
			Proof.device("unlock/UnlockKeysTest", "theMachineKeyBindsTheRecordToThisDevice"),
			Proof.device("threatmodel/BoundaryTest", "withTheMachineIdReadOnceGuessingCostsOnlyArgon2"),
		),
		"The content key never rotates" to listOf(
			Proof.device("sync/RecoveryServerTest", "aRotationOnAnotherPhoneAsksForTheCurrentWordsFirst"),
			Proof.shared("threatmodel/RecoveryBlobBoundaryTest", "aBlobFromBeforeAPhraseChangeStillOpensWithTheOldWords"),
		),
	)

	private fun claims(): List<String> {
		val architecture = File(repository, "docs/ARCHITECTURE.md").readText()
		val section = architecture.substringAfter("\n## Threat model\n").substringBefore("\n## ")
		return section.split("\n").mapNotNull { line ->
			when {
				line.startsWith("| ") && !line.startsWith("| Actor") && !line.startsWith("| ---") -> line.split("|")[1].trim()
				line.startsWith("- **") -> line.removePrefix("- **").substringBefore("**").removeSuffix(".")
				line.startsWith("- ") -> line.removePrefix("- ").substringBefore(" — ")
				else -> null
			}
		}
	}

	@Test
	fun everyThreatModelClaimNamesTestsThatProveItOnAndroid() {
		val claims = claims()

		assertEquals(proofs.size, claims.size)
		assertEquals("unproven: ${claims - proofs.keys}; stale: ${proofs.keys - claims.toSet()}", proofs.keys, claims.toSet())
	}

	@Test
	fun everyNamedProofIsATestThatRunsAndExpectsSomething() {
		for ((claim, named) in proofs) {
			assertTrue(claim, named.isNotEmpty())
			for (proof in named) {
				val source = File(repository, proof.file).readText()
				assertNull("$claim: ${proof.name} in ${proof.file}", proof.flaw(source))
			}
		}
	}

	@Test
	fun aKotlinProofCountsOnlyAsARunningTestWithAnAssertion() {
		val cases = listOf(
			"\t@Test\n\tfun proof() {\n\t\tassertTrue(open())\n\t}" to null,
			"\t@Test\n\tfun proof() = assertEquals(1, one())" to null,
			"\t@Test\n\tfun proof() = runBlocking {\n\t\tassertEquals(1, one())\n\t}" to null,
			"\t@Test fun proof() { assertTrue(true) }" to null,
			"\t@Test\n\tfun another() {\n\t\tassertTrue(true)\n\t}" to "has no fun proof(",
			"\tprivate fun proof() {\n\t\tassertTrue(true)\n\t}" to "is not marked @Test",
			"\t@Test\n\tfun other() {\n\t\tassertTrue(true)\n\t}\n\tfun proof() {\n\t\tassertTrue(true)\n\t}" to "is not marked @Test",
			"\t@Ignore(\"later\")\n\t@Test\n\tfun proof() {\n\t\tassertTrue(true)\n\t}" to "is disabled",
			"\t@Test\n\tfun proof() {\n\t\topen()\n\t}" to "expects nothing",
			"\t@Test\n\tfun proof() {\n\t\t// assertTrue(opened)\n\t}" to "expects nothing",
			"\t@Test\n\tfun proof() {\n\t\tsetUp()\n\t}\n\n\t@Test\n\tfun next() {\n\t\tassertTrue(true)\n\t}" to "expects nothing",
		)
		for ((source, flaw) in cases) assertEquals(source, flaw, ProofSource.flawOfKotlinTest("proof", source))
	}

	@Test
	fun swiftAndRustProofsCountOnlyAsRunningTestsWithAnExpectation() {
		assertNull(ProofSource.flawOfSwiftTest("proof", "\t@Test func proof() async throws {\n\t\tlet opened = try open()\n\t\t#expect(opened)\n\t}"))
		assertEquals("is disabled", ProofSource.flawOfSwiftTest("proof", "\t@Test(.disabled(\"later\")) func proof() {\n\t\t#expect(true)\n\t}"))
		assertNull(ProofSource.flawOfRustTest("proof", "#[test]\nfn proof() {\n\tassert_eq!(status(), 413);\n}"))
		assertEquals("is disabled", ProofSource.flawOfRustTest("proof", "#[test]\n#[ignore]\nfn proof() {\n\tassert!(true);\n}"))
		assertEquals("expects nothing", ProofSource.flawOfRustTest("proof", "#[test]\nfn proof() {\n\tlet _ = status();\n}\n\n#[test]\nfn next() {\n\tassert!(true);\n}"))
	}
}
