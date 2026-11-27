package dev.hloth.nativenote.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.LocalRippleThemeConfiguration
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.RippleDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext

@Composable
fun NativeNoteTheme(content: @Composable () -> Unit) {
	val context = LocalContext.current
	val dark = isSystemInDarkTheme()
	val colorScheme = remember(context, LocalConfiguration.current, dark) { systemColorScheme(context, dark) }
	MaterialExpressiveTheme(colorScheme = colorScheme) {
		CompositionLocalProvider(LocalRippleThemeConfiguration provides RippleDefaults.InsetFocusRingThemeConfiguration, content = content)
	}
}
