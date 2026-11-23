package dev.hloth.nativenote.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.Failure
import dev.hloth.nativenote.support.hasHint
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AccessScreensTest {
	@get:Rule
	val compose = createComposeRule()

	private fun text(id: Int) = InstrumentationRegistry.getInstrumentation().targetContext.getString(id)

	private fun node(id: Int) = compose.onNodeWithText(text(id))
	private fun field(id: Int) = compose.onNode(hasHint(text(id)))

	private fun dialogButton(id: Int) = compose.onNode(hasText(text(id)) and hasClickAction() and hasAnyAncestor(isDialog()))

	@Test
	fun onboardingWelcomesThenRefusesMismatchedPasswords() {
		val submitted = mutableListOf<String>()
		compose.setContent { OnboardingScreen(hasSecureHardware = true, isWorking = false, onSetUp = { submitted += it }) }

		node(R.string.welcome_title).assertIsDisplayed()
		node(R.string.next).performClick()
		node(R.string.password_title).assertIsDisplayed()
		node(R.string.next).assertIsNotEnabled()

		field(R.string.password).performTextInput("correct horse")
		field(R.string.confirm_password).performTextInput("correct hose")
		node(R.string.next).performClick()

		node(R.string.passwords_mismatch).assertIsDisplayed()
		assertEquals(emptyList<String>(), submitted)
	}

	@Test
	fun onboardingSubmitsWhenBothPasswordsMatch() {
		val submitted = mutableListOf<String>()
		compose.setContent { OnboardingScreen(hasSecureHardware = true, isWorking = false, onSetUp = { submitted += it }) }
		node(R.string.next).performClick()

		field(R.string.password).performTextInput("correct horse")
		field(R.string.confirm_password).performTextInput("correct horse")
		node(R.string.next).assertIsEnabled().performClick()

		assertEquals(listOf("correct horse"), submitted)
	}

	@Test
	fun onboardingWarnsWithoutSecureHardware() {
		compose.setContent { OnboardingScreen(hasSecureHardware = false, isWorking = false, onSetUp = {}) }
		node(R.string.next).performClick()

		node(R.string.no_secure_hardware).assertIsDisplayed()
	}

	@Test
	fun unlockSubmitsThePasswordAndReportsAWrongOne() {
		val submitted = mutableListOf<String>()
		var wrong by mutableStateOf(false)
		compose.setContent { UnlockScreen(wrongPassword = wrong, isWorking = false, onUnlock = { submitted += it }, onErase = {}) }

		node(R.string.unlock).assertIsNotEnabled()
		field(R.string.password).performTextInput("guess")
		node(R.string.unlock).performClick()
		assertEquals(listOf("guess"), submitted)

		wrong = true
		node(R.string.wrong_password).assertIsDisplayed()
	}

	@Test
	fun forgettingThePasswordErasesOnlyAfterConfirming() {
		var erased = 0
		compose.setContent { UnlockScreen(wrongPassword = false, isWorking = false, onUnlock = {}, onErase = { erased++ }) }

		node(R.string.forgot_password).performClick()
		node(R.string.erase_title).assertIsDisplayed()
		dialogButton(R.string.cancel).performClick()
		assertEquals(0, erased)

		node(R.string.forgot_password).performClick()
		dialogButton(R.string.erase_action).performClick()
		assertEquals(1, erased)
	}

	@Test
	fun changingThePasswordChecksTheNewOneTwiceAndShowsAFailure() {
		val attempts = mutableListOf<Pair<String, String>>()
		var answer: Failure? = Failure.WrongPassword
		compose.setContent {
			SettingsScreen(onBack = {}, onChangePassword = { current, new ->
				attempts += current to new
				answer
			})
		}
		node(R.string.change_password).performClick()

		field(R.string.current_password).performTextInput("old")
		field(R.string.new_password).performTextInput("new one")
		field(R.string.verify_password).performTextInput("new on")
		dialogButton(R.string.change_password).performClick()
		node(R.string.new_passwords_mismatch).assertIsDisplayed()
		assertEquals(emptyList<Pair<String, String>>(), attempts)

		field(R.string.verify_password).performTextInput("e")
		dialogButton(R.string.change_password).performClick()
		node(R.string.wrong_password).assertIsDisplayed()
		assertEquals(listOf("old" to "new one"), attempts)

		answer = null
		dialogButton(R.string.change_password).performClick()
		node(R.string.change_password_explanation).assertDoesNotExist()
	}

	@Test
	fun aFilledPasswordFieldKeepsItsNameAsAHintThatDoesNotReplaceItsValue() {
		compose.setContent { UnlockScreen(wrongPassword = false, isWorking = false, onUnlock = {}, onErase = {}) }

		field(R.string.password).performTextInput("typed")

		val semantics = field(R.string.password).fetchSemanticsNode().config
		assertFalse(SemanticsProperties.ContentDescription in semantics)
	}

	@Test
	fun settingsOpensTheThirdPartyLicenses() {
		var opened = false
		compose.setContent { SettingsScreen(onBack = {}, onChangePassword = { _, _ -> null }, onLicenses = { opened = true }) }

		node(R.string.third_party_licenses).performClick()

		assertTrue(opened)
	}

	@Test
	fun theLicensesScreenShowsEveryNoticeThroughTheApacheTermsAndGoesBack() {
		var closed = false
		compose.setContent { LicensesScreen(onBack = { closed = true }) }

		compose.onNodeWithText("SQLCipher").assertIsDisplayed()
		compose.onNode(hasScrollAction()).performScrollToNode(hasText("END OF TERMS AND CONDITIONS"))
		compose.onNodeWithText("END OF TERMS AND CONDITIONS").assertIsDisplayed()
		compose.onNodeWithContentDescription(text(R.string.back)).performClick()

		assertTrue(closed)
	}
}
