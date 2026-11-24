package dev.hloth.nativenote.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.DeviceConfigurationOverride
import androidx.compose.ui.test.ForcedSize
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.assertIsNotFocused
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isFocused
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.support.FakeServer
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.support.hasHint
import dev.hloth.nativenote.support.onMain
import dev.hloth.nativenote.support.pressBack
import dev.hloth.nativenote.sync.Request
import dev.hloth.nativenote.sync.SyncTransport
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SyncSetupScreenTest {
	@get:Rule
	val folder = TemporaryFolder()

	@get:Rule
	val compose = createComposeRule()

	private val context = InstrumentationRegistry.getInstrumentation().targetContext
	private val server = FakeServer()
	private var size by mutableStateOf(DpSize(400.dp, 800.dp))
	private var done = false

	private fun text(id: Int) = context.getString(id)

	private fun word(number: Int) = compose.onNode(hasHint(context.getString(R.string.word_number, number)))

	private fun button(id: Int) = compose.onNodeWithText(text(id))

	private fun shown(id: Int) = compose.onAllNodes(hasText(text(id))).fetchSemanticsNodes().isNotEmpty()

	private fun waitFor(id: Int) = compose.waitUntil(10_000) { shown(id) }

	private fun library(transport: SyncTransport = server): AppModel {
		val model = appModel(folder.root, makeTransport = { transport })
		model.await { start() }
		model.await { setUp("correct horse") }
		onMain { model.finishOnboarding() }
		return model
	}

	private fun show(model: AppModel) = compose.setContent {
		DeviceConfigurationOverride(DeviceConfigurationOverride.ForcedSize(size)) {
			NativeNoteTheme { SyncSetupScreen(model, SyncSetupMode.SetUp, onDone = { done = true }) }
		}
	}

	private fun enterServer() {
		compose.onNode(hasHint(text(R.string.server))).performTextInput(FakeServer.ADDRESS)
		compose.onNode(hasHint(text(R.string.api_key))).performTextInput(server.apiKeyHex)
		button(R.string.continue_action).performClick()
	}

	private fun wordsOnScreen() = (1..24).mapNotNull { number ->
		compose.onAllNodes(hasText("$number. ", substring = true)).fetchSemanticsNodes()
			.mapNotNull { it.config.getOrNull(SemanticsProperties.Text)?.joinToString() }
			.firstOrNull { it.startsWith("$number. ") }?.removePrefix("$number. ")
	}

	private fun firstWordNode(number: Int) = compose.onAllNodes(hasText("$number. ", substring = true)).fetchSemanticsNodes()
		.single { node -> node.config.getOrNull(SemanticsProperties.Text)?.joinToString().orEmpty().startsWith("$number. ") }

	@Test
	fun backCancelsTheServerCheckAndKeepsTheScreen() {
		val model = library { awaitCancellation() }
		show(model)
		enterServer()
		compose.waitUntil(5_000) { compose.onAllNodes(hasText(text(R.string.continue_action))).fetchSemanticsNodes().single().config.contains(SemanticsProperties.Disabled) }

		pressBack()

		compose.waitUntil(5_000) { !compose.onAllNodes(hasText(text(R.string.continue_action))).fetchSemanticsNodes().single().config.contains(SemanticsProperties.Disabled) }
		compose.onNode(hasHint(text(R.string.server))).assertIsEnabled()
		assertFalse(done)
		assertEquals(AppModel.Phase.Unlocked, onMain { model.phase })
	}

	@Test
	fun theRevealedWordsTakeFocusAndScrollWithTheKeyboard() {
		size = DpSize(360.dp, 640.dp)
		show(library())
		enterServer()
		waitFor(R.string.reveal)
		button(R.string.reveal).performClick()
		compose.waitForIdle()

		assertTrue(firstWordNode(1).config[SemanticsProperties.Focused])
		assertEquals(24, wordsOnScreen().size)
		for (press in 1..23) compose.onNode(isFocused()).performKeyInput { pressKey(Key.Tab) }
		compose.onNode(hasText("24. ", substring = true)).assertIsDisplayed().assertIsFocused()
	}

	@Test
	fun twoColumnsOfWordsReadDownEachColumn() {
		size = DpSize(600.dp, 800.dp)
		show(library())
		enterServer()
		waitFor(R.string.reveal)
		button(R.string.reveal).performClick()
		compose.waitForIdle()

		val (first, second, last) = listOf(1, 2, 13).map { firstWordNode(it).parent!! }
		assertEquals(first.id, second.id)
		assertNotEquals(first.id, last.id)
		assertTrue(first.config[SemanticsProperties.IsTraversalGroup])
	}

	@Test
	fun aSecondAttemptHidesItsNewWordsAgain() {
		show(library())
		enterServer()
		waitFor(R.string.reveal)
		button(R.string.reveal).performClick()
		assertEquals(24, wordsOnScreen().size)

		compose.onNodeWithContentDescription(text(R.string.back)).performClick()
		button(R.string.continue_action).performClick()

		waitFor(R.string.reveal)
		assertEquals(emptyList<String>(), wordsOnScreen())
	}

	@Test
	fun backWhileTheWordsAreStoredNeitherLeavesNorCancels() {
		val putting = CompletableDeferred<Unit>()
		val answer = CompletableDeferred<Unit>()
		server.beforeReply = { request ->
			if (request is Request.Put) {
				putting.complete(Unit)
				answer.await()
			}
		}
		val model = library()
		show(model)
		confirmWords()
		compose.waitUntil(10_000) { putting.isCompleted }

		pressBack()
		assertFalse(done)
		assertEquals(AppModel.Phase.Unlocked, onMain { model.phase })

		answer.complete(Unit)
		compose.waitUntil(10_000) { done }
		assertEquals(1u, server.blobVersion)
	}

	private fun confirmWords() {
		enterServer()
		waitFor(R.string.reveal)
		button(R.string.reveal).performClick()
		val words = wordsOnScreen()
		button(R.string.continue_action).performClick()
		waitFor(R.string.confirm_phrase)
		for (number in 1..24) {
			val field = compose.onAllNodes(hasHint(context.getString(R.string.word_number, number)))
			if (field.fetchSemanticsNodes().isNotEmpty()) word(number).performTextInput(words[number - 1])
		}
		button(R.string.turn_on_sync).performClick()
	}

	@Test
	fun aServerThatGainedALibraryMeanwhileSaysSoOnTheJoinStep() {
		server.beforeReply = { request ->
			if (request == Request.Get && server.blobVersion == 0u) {
				server.blob = ByteArray(64)
				server.blobVersion = 1u
			}
		}
		show(library())
		confirmWords()

		waitFor(R.string.enter_phrase)
		compose.onNodeWithText(text(R.string.setup_server_has_library)).assertIsDisplayed()
		word(1).assertIsNotFocused()

		word(1).performTextInput("a")
		assertFalse(shown(R.string.setup_server_has_library))
	}

	@Test
	fun rotatingWhileEnteringThePhraseKeepsTheWordBeingTyped() {
		server.blob = ByteArray(64)
		server.blobVersion = 1u
		size = DpSize(320.dp, 800.dp)
		show(library())
		enterServer()
		waitFor(R.string.enter_phrase)
		word(5).performScrollTo().performClick()
		word(5).assertIsFocused()

		size = DpSize(700.dp, 400.dp)
		compose.waitForIdle()
		word(5).assertIsFocused()

		size = DpSize(320.dp, 800.dp)
		compose.waitForIdle()
		word(5).assertIsFocused()
	}

	@Test
	fun aFailureIsAssertiveAndTheStepOpensOnItsFirstField() {
		show(library())
		compose.onNode(hasHint(text(R.string.server))).assertIsFocused()
		compose.onNode(hasHint(text(R.string.server))).performTextInput("not an address")
		compose.onNode(hasHint(text(R.string.api_key))).performTextInput(server.apiKeyHex)
		button(R.string.continue_action).performClick()

		waitFor(R.string.setup_invalid_server)
		assertEquals(LiveRegionMode.Assertive, compose.onNodeWithText(text(R.string.setup_invalid_server)).fetchSemanticsNode().config[SemanticsProperties.LiveRegion])
	}
}
