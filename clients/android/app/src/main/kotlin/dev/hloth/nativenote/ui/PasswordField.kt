package dev.hloth.nativenote.ui

import android.view.inputmethod.EditorInfo
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.material3.OutlinedSecureTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.InterceptPlatformTextInput
import androidx.compose.ui.platform.PlatformTextInputMethodRequest
import androidx.compose.ui.semantics.hintText
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType

@Composable
fun PasswordField(
	state: TextFieldState,
	label: String,
	modifier: Modifier = Modifier,
	enabled: Boolean = true,
	error: String? = null,
	imeAction: ImeAction = ImeAction.Done,
	onAction: () -> Unit = {},
) {
	NoPersonalizedLearning {
		OutlinedSecureTextField(
			state = state,
			modifier = modifier.fillMaxWidth().semantics { hintText = label },
			enabled = enabled,
			placeholder = { Text(label) },
			isError = error != null,
			supportingText = error?.let { { Text(it) } },
			keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = imeAction),
			onKeyboardAction = { onAction() },
		)
	}
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
