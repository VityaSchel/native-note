package dev.hloth.nativenote.ui

import android.view.View
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.InputMode
import androidx.compose.ui.input.InputModeManager
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.platform.LocalInputModeManager
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.DeviceConfigurationOverride
import androidx.compose.ui.test.FontScale
import androidx.compose.ui.test.ForcedSize
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasProgressBarRangeInfo
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.isFocused
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performImeAction
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.test.requestFocus
import androidx.compose.ui.test.then
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.Failure
import dev.hloth.nativenote.support.hasHint
import dev.hloth.nativenote.support.pressBack
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
		field(R.string.current_password).assertIsFocused()
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

	@Test
	fun anEmptyFieldIsNamedOnce() {
		compose.setContent { UnlockScreen(wrongPassword = false, isWorking = false, onUnlock = {}, onErase = {}) }

		assertFalse(SemanticsProperties.Text in field(R.string.password).fetchSemanticsNode().config)
	}

	@Test
	fun aFieldsErrorIsItsMessage() {
		compose.setContent { UnlockScreen(wrongPassword = true, isWorking = false, onUnlock = {}, onErase = {}) }

		assertEquals(text(R.string.wrong_password), field(R.string.password).fetchSemanticsNode().config[SemanticsProperties.Error])
	}

	@Test
	fun aMismatchGoesAwayWhenTheFieldIsEditedAndComesBackWhenRepeated() {
		compose.setContent { OnboardingScreen(hasSecureHardware = true, isWorking = false, onSetUp = {}) }
		node(R.string.next).performClick()
		field(R.string.password).performTextInput("correct horse")
		field(R.string.confirm_password).performTextInput("correct")
		node(R.string.next).performClick()
		node(R.string.passwords_mismatch).assertIsDisplayed()
		field(R.string.confirm_password).assertIsFocused()

		field(R.string.confirm_password).performTextInput(" h")
		node(R.string.passwords_mismatch).assertDoesNotExist()
		node(R.string.next).performClick()
		node(R.string.passwords_mismatch).assertIsDisplayed()
	}

	@Test
	fun theNextKeyMovesToTheNextField() {
		compose.setContent { OnboardingScreen(hasSecureHardware = true, isWorking = false, onSetUp = {}) }
		node(R.string.next).performClick()

		field(R.string.password).performTextInput("correct horse")
		field(R.string.password).performImeAction()

		field(R.string.confirm_password).assertIsFocused()
	}

	@Test
	fun backOnThePasswordStepReturnsToWelcome() {
		compose.setContent { OnboardingScreen(hasSecureHardware = true, isWorking = false, onSetUp = {}) }
		node(R.string.next).performClick()
		node(R.string.password_title).assertIsDisplayed()

		pressBack()

		node(R.string.welcome_title).assertIsDisplayed()
	}

	@Test
	fun cancelingTheBiometricPromptStaysOnTheOffer() {
		var finished = false
		var offers by mutableStateOf(false)
		compose.setContent {
			OnboardingScreen(hasSecureHardware = true, isWorking = false, onSetUp = { offers = true }, offersBiometrics = offers, isBiometricUnlockOn = { false }, onFinish = { finished = true })
		}
		setPassword()

		node(R.string.set_up_biometric_unlock).performClick()
		compose.waitForIdle()

		assertFalse(finished)
		node(R.string.biometric_offer_title).assertIsDisplayed()
	}

	@Test
	fun theBiometricOfferIsOverOnceTheTypedPasswordIsGone() {
		var finished = false
		compose.setContent { OnboardingScreen(hasSecureHardware = true, isWorking = false, onSetUp = {}, offersBiometrics = true, onFinish = { finished = true }) }

		compose.waitUntil(5_000) { finished }
		node(R.string.set_up_biometric_unlock).assertDoesNotExist()
	}

	private fun setPassword() {
		node(R.string.next).performClick()
		field(R.string.password).performTextInput("correct horse")
		field(R.string.confirm_password).performTextInput("correct horse")
		node(R.string.next).performClick()
	}

	@Test
	fun theBiometricRowSaysWhetherItIsOn() {
		compose.setContent { SettingsScreen(onBack = {}, onChangePassword = { _, _ -> null }, biometricUnlock = true) }

		node(R.string.biometric_unlock).assertIsOn()
		assertEquals(Role.Switch, node(R.string.biometric_unlock).fetchSemanticsNode().config[SemanticsProperties.Role])
	}

	@Test
	fun everyScreenHasAPaneTitleAndHeadings() {
		var shown by mutableStateOf<@Composable () -> Unit>({})
		compose.setContent { shown() }
		val screens = listOf<@Composable () -> Unit>(
			{ OnboardingScreen(hasSecureHardware = true, isWorking = false, onSetUp = {}) },
			{ UnlockScreen(wrongPassword = false, isWorking = false, onUnlock = {}, onErase = {}) },
			{ SettingsScreen(onBack = {}, onChangePassword = { _, _ -> null }) },
			{ LicensesScreen(onBack = {}) },
		)
		for (screen in screens) {
			shown = screen
			compose.waitForIdle()
			assertEquals(1, compose.onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsProperties.PaneTitle)).fetchSemanticsNodes().size)
			assertTrue(compose.onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading)).fetchSemanticsNodes().isNotEmpty())
		}
	}

	@Test
	fun aBusyButtonKeepsItsNameAndItsSpinnerIsSilent() {
		compose.setContent {
			host = LocalView.current
			UnlockScreen(wrongPassword = false, isWorking = true, onUnlock = {}, onErase = {})
		}

		assertEquals(text(R.string.busy), node(R.string.unlock).fetchSemanticsNode().config[SemanticsProperties.StateDescription])
		compose.onNode(hasProgressBarRangeInfo(ProgressBarRangeInfo.Indeterminate), useUnmergedTree = true).assertDoesNotExist()
		val label = compose.onNodeWithText(text(R.string.unlock), useUnmergedTree = true).fetchSemanticsNode()
		val info = compose.runOnIdle { host!!.accessibilityNodeProvider.createAccessibilityNodeInfo(label.id)!! }
		assertTrue(info.isVisibleToUser)
	}

	@Test
	fun theActionKeepsItsFocusWhenTheKeyboardTakesTheRoom() {
		var height by mutableStateOf(500.dp)
		val focus = FocusRequester()
		compose.setContent {
			inputMode = LocalInputModeManager.current
			Box(Modifier.height(height)) {
				FormPage(pane = "Pane", title = "Title", icon = R.drawable.ic_lock, actions = { Button(onClick = {}, Modifier.focusRequester(focus)) { Text("Action") } }) {
					Button(onClick = {}) { Text("First") }
				}
			}
		}
		compose.runOnIdle {
			inputMode!!.requestInputMode(InputMode.Keyboard)
			focus.requestFocus()
		}
		compose.onNodeWithText("Action").assertIsFocused()

		for (next in listOf(250.dp, 500.dp)) {
			height = next
			compose.onNodeWithText("Action").assertIsFocused()
		}
	}

	@Test
	fun theLicensesScrollWithAKeyboardAlone() {
		compose.setContent {
			inputMode = LocalInputModeManager.current
			LicensesScreen(onBack = {})
		}
		compose.runOnIdle { inputMode!!.requestInputMode(InputMode.Keyboard) }
		compose.onNodeWithContentDescription(text(R.string.back)).requestFocus()
		compose.onNodeWithText("SQLCipher").assertIsDisplayed()

		repeat(12) { compose.onNode(isFocused()).performKeyInput { pressKey(Key.Tab) } }
		compose.onNode(isFocused()).performKeyInput { pressKey(Key.PageDown) }
		compose.waitForIdle()

		compose.onNodeWithText("SQLCipher").assertIsNotDisplayed()
	}

	private var host: View? = null
	private var inputMode: InputModeManager? = null

	@Test
	fun atTheLargestTextOnANarrowPhoneTheUnlockButtonKeepsItsLabelOnOneLine() {
		compose.setContent {
			DeviceConfigurationOverride(DeviceConfigurationOverride.FontScale(2f) then DeviceConfigurationOverride.ForcedSize(DpSize(320.dp, 640.dp))) {
				UnlockScreen(wrongPassword = false, isWorking = false, onUnlock = {}, onErase = {})
			}
		}

		val layouts = mutableListOf<TextLayoutResult>()
		compose.onNodeWithText(text(R.string.unlock), useUnmergedTree = true).performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
		val label = layouts.single()
		assertEquals(1, label.lineCount)
		assertTrue(label.getLineRight(0) - label.getLineLeft(0) <= label.size.width + 1)
		assertTrue(label.getLineBottom(0) <= label.size.height + 1)
	}
}
