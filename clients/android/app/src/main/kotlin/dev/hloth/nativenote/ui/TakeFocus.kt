package dev.hloth.nativenote.ui

import android.view.accessibility.AccessibilityManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.delay

@Composable
fun TakeFocus(focus: FocusRequester, takes: Boolean = true, onTaken: () -> Unit = {}) {
	val accessibility = LocalContext.current.getSystemService(AccessibilityManager::class.java)
	LaunchedEffect(takes) {
		if (!takes) return@LaunchedEffect
		if (accessibility.isTouchExplorationEnabled) delay(SCREEN_CHANGE_IS_ANNOUNCED)
		focus.requestFocus()
		onTaken()
	}
}

private const val SCREEN_CHANGE_IS_ANNOUNCED = 1_000L
