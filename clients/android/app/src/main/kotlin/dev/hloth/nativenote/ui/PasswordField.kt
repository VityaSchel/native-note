package dev.hloth.nativenote.ui

import android.view.inputmethod.EditorInfo
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.KeyboardActionHandler
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.material3.OutlinedSecureTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.InterceptPlatformTextInput
import androidx.compose.ui.platform.LocalAutofillManager
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.PlatformTextInputMethodRequest
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.error
import androidx.compose.ui.semantics.hideFromAccessibility
import androidx.compose.ui.semantics.hintText
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import kotlinx.coroutines.flow.drop

@Composable
fun PasswordField(
	state: TextFieldState,
	label: String,
	enabled: Boolean = true,
	error: String? = null,
	takesFocus: Boolean = false,
	imeAction: ImeAction = ImeAction.Done,
	onEdit: () -> Unit = {},
	onAction: (() -> Unit)? = null,
) {
	val focus = remember { FocusRequester() }
	val inView = remember { BringIntoViewRequester() }
	val edited by rememberUpdatedState(onEdit)
	val keyboard = WindowInsets.ime.getBottom(LocalDensity.current)
	TakeFocus(focus, takesFocus)
	NeverOfferedForSaving(state)
	LaunchedEffect(state) { snapshotFlow { state.text.toString() }.drop(1).collect { edited() } }
	LaunchedEffect(error) { if (error != null) focus.requestFocus() }
	LaunchedEffect(error, keyboard) { if (error != null) inView.bringIntoView() }
	NoPersonalizedLearning {
		OutlinedSecureTextField(
			state = state,
			modifier = Modifier.fillMaxWidth().bringIntoViewRequester(inView).focusRequester(focus).semantics {
				hintText = label
				if (error != null) error(error)
			},
			enabled = enabled,
			label = { Text(label, Modifier.clearAndSetSemantics {}) },
			isError = error != null,
			supportingText = error?.let { { Text(it, Modifier.semantics { hideFromAccessibility() }) } },
			keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = imeAction),
			onKeyboardAction = onAction?.let { action -> KeyboardActionHandler { action() } },
		)
	}
}

@Composable
fun NeverOfferedForSaving(state: TextFieldState) {
	val autofill = LocalAutofillManager.current
	LaunchedEffect(state, autofill) { snapshotFlow { state.text.toString() }.drop(1).collect { autofill?.cancel() } }
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun NoPersonalizedLearning(content: @Composable () -> Unit) {
	InterceptPlatformTextInput(
		interceptor = { request, nextHandler ->
			val incognito = object : PlatformTextInputMethodRequest by request {
				override fun createInputConnection(outAttributes: EditorInfo) = request.createInputConnection(outAttributes).also {
					outAttributes.imeOptions = outAttributes.imeOptions or EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
				}
			}
			nextHandler.startInputMethod(incognito)
		},
		content = content,
	)
}
