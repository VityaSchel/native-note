package dev.hloth.nativenote.ui

import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

@Composable
fun DialogBody(content: @Composable ColumnScope.() -> Unit) {
	val scroll = rememberScrollState()
	Column(
		Modifier.verticalScroll(scroll).focusable(enabled = scroll.canScrollForward || scroll.canScrollBackward),
		verticalArrangement = Arrangement.spacedBy(8.dp),
		content = content,
	)
}

@Composable
fun maxDialogWidth(): Dp = LocalWindowInfo.current.containerDpSize.width - DIALOG_MARGIN * 2

private val DIALOG_MARGIN = 24.dp
