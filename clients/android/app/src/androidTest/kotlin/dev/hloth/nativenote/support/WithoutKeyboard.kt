package dev.hloth.nativenote.support

import androidx.compose.runtime.Composable
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.platform.InterceptPlatformTextInput
import kotlinx.coroutines.awaitCancellation

@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun WithoutKeyboard(content: @Composable () -> Unit) = InterceptPlatformTextInput(interceptor = { _, _ -> awaitCancellation() }, content = content)
