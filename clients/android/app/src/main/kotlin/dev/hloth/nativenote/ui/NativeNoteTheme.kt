package dev.hloth.nativenote.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.LocalRippleThemeConfiguration
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.RippleDefaults
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalContext

@Composable
fun NativeNoteTheme(content: @Composable () -> Unit) {
	val context = LocalContext.current
	val colorScheme = if (isSystemInDarkTheme()) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
	MaterialExpressiveTheme(colorScheme = colorScheme) {
		CompositionLocalProvider(LocalRippleThemeConfiguration provides RippleDefaults.InsetFocusRingThemeConfiguration, content = content)
	}
}
