package dev.hloth.nativenote.ui

import android.app.UiModeManager
import android.content.Context
import android.os.Build
import androidx.annotation.ColorInt
import androidx.annotation.ColorRes
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.core.graphics.ColorUtils
import kotlin.math.abs

fun systemColorScheme(context: Context, dark: Boolean): ColorScheme {
	val roles = if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
	if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return roles
	val accent = context.getColor(if (dark) android.R.color.system_accent1_200 else android.R.color.system_accent1_600)
	val contrast = context.getSystemService(UiModeManager::class.java).contrast
	return if (contrast > 0 || followsPalette(roles.primary.toArgb(), accent)) roles else PaletteColors(context::getColor).scheme(dark)
}

fun followsPalette(@ColorInt role: Int, @ColorInt accent: Int): Boolean {
	val (roleHue, roleChroma) = hueAndChroma(role)
	val (accentHue, accentChroma) = hueAndChroma(accent)
	if (roleChroma < GRAY || accentChroma < GRAY) return roleChroma < GRAY && accentChroma < GRAY
	val apart = abs(roleHue - accentHue)
	return minOf(apart, 360 - apart) <= SAME_HUE
}

class PaletteColors(private val color: (Int) -> Int) {
	fun scheme(dark: Boolean): ColorScheme = if (dark) dark() else light()

	private fun system(@ColorRes id: Int) = Color(color(id))

	private fun neutral(tone: Int): Color {
		val (hue, chroma) = hueAndChroma(color(android.R.color.system_neutral2_600))
		return Color(ColorUtils.M3HCTToColor(hue, chroma, tone.toFloat()))
	}

	private fun light() = lightColorScheme(
		primary = system(android.R.color.system_accent1_600),
		onPrimary = system(android.R.color.system_accent1_0),
		primaryContainer = system(android.R.color.system_accent1_100),
		onPrimaryContainer = system(android.R.color.system_accent1_900),
		inversePrimary = system(android.R.color.system_accent1_200),
		secondary = system(android.R.color.system_accent2_600),
		onSecondary = system(android.R.color.system_accent2_0),
		secondaryContainer = system(android.R.color.system_accent2_100),
		onSecondaryContainer = system(android.R.color.system_accent2_900),
		tertiary = system(android.R.color.system_accent3_600),
		onTertiary = system(android.R.color.system_accent3_0),
		tertiaryContainer = system(android.R.color.system_accent3_100),
		onTertiaryContainer = system(android.R.color.system_accent3_900),
		background = neutral(98),
		onBackground = system(android.R.color.system_neutral2_900),
		surface = neutral(98),
		onSurface = system(android.R.color.system_neutral2_900),
		surfaceVariant = system(android.R.color.system_neutral2_100),
		onSurfaceVariant = system(android.R.color.system_neutral2_700),
		surfaceTint = system(android.R.color.system_accent1_600),
		inverseSurface = system(android.R.color.system_neutral2_800),
		inverseOnSurface = system(android.R.color.system_neutral2_50),
		outline = system(android.R.color.system_neutral2_500),
		outlineVariant = system(android.R.color.system_neutral2_200),
		scrim = system(android.R.color.system_neutral2_1000),
		surfaceBright = neutral(98),
		surfaceDim = neutral(87),
		surfaceContainerLowest = system(android.R.color.system_neutral2_0),
		surfaceContainerLow = neutral(96),
		surfaceContainer = neutral(94),
		surfaceContainerHigh = neutral(92),
		surfaceContainerHighest = system(android.R.color.system_neutral2_100),
		primaryFixed = system(android.R.color.system_accent1_100),
		primaryFixedDim = system(android.R.color.system_accent1_200),
		onPrimaryFixed = system(android.R.color.system_accent1_900),
		onPrimaryFixedVariant = system(android.R.color.system_accent1_700),
		secondaryFixed = system(android.R.color.system_accent2_100),
		secondaryFixedDim = system(android.R.color.system_accent2_200),
		onSecondaryFixed = system(android.R.color.system_accent2_900),
		onSecondaryFixedVariant = system(android.R.color.system_accent2_700),
		tertiaryFixed = system(android.R.color.system_accent3_100),
		tertiaryFixedDim = system(android.R.color.system_accent3_200),
		onTertiaryFixed = system(android.R.color.system_accent3_900),
		onTertiaryFixedVariant = system(android.R.color.system_accent3_700),
	)

	private fun dark() = darkColorScheme(
		primary = system(android.R.color.system_accent1_200),
		onPrimary = system(android.R.color.system_accent1_800),
		primaryContainer = system(android.R.color.system_accent1_700),
		onPrimaryContainer = system(android.R.color.system_accent1_100),
		inversePrimary = system(android.R.color.system_accent1_600),
		secondary = system(android.R.color.system_accent2_200),
		onSecondary = system(android.R.color.system_accent2_800),
		secondaryContainer = system(android.R.color.system_accent2_700),
		onSecondaryContainer = system(android.R.color.system_accent2_100),
		tertiary = system(android.R.color.system_accent3_200),
		onTertiary = system(android.R.color.system_accent3_800),
		tertiaryContainer = system(android.R.color.system_accent3_700),
		onTertiaryContainer = system(android.R.color.system_accent3_100),
		background = neutral(6),
		onBackground = system(android.R.color.system_neutral2_100),
		surface = neutral(6),
		onSurface = system(android.R.color.system_neutral2_100),
		surfaceVariant = system(android.R.color.system_neutral2_700),
		onSurfaceVariant = system(android.R.color.system_neutral2_200),
		surfaceTint = system(android.R.color.system_accent1_200),
		inverseSurface = system(android.R.color.system_neutral2_100),
		inverseOnSurface = system(android.R.color.system_neutral2_800),
		outline = system(android.R.color.system_neutral2_400),
		outlineVariant = system(android.R.color.system_neutral2_700),
		scrim = system(android.R.color.system_neutral2_1000),
		surfaceBright = neutral(24),
		surfaceDim = neutral(6),
		surfaceContainerLowest = neutral(4),
		surfaceContainerLow = system(android.R.color.system_neutral2_900),
		surfaceContainer = neutral(12),
		surfaceContainerHigh = neutral(17),
		surfaceContainerHighest = neutral(22),
		primaryFixed = system(android.R.color.system_accent1_100),
		primaryFixedDim = system(android.R.color.system_accent1_200),
		onPrimaryFixed = system(android.R.color.system_accent1_900),
		onPrimaryFixedVariant = system(android.R.color.system_accent1_700),
		secondaryFixed = system(android.R.color.system_accent2_100),
		secondaryFixedDim = system(android.R.color.system_accent2_200),
		onSecondaryFixed = system(android.R.color.system_accent2_900),
		onSecondaryFixedVariant = system(android.R.color.system_accent2_700),
		tertiaryFixed = system(android.R.color.system_accent3_100),
		tertiaryFixedDim = system(android.R.color.system_accent3_200),
		onTertiaryFixed = system(android.R.color.system_accent3_900),
		onTertiaryFixedVariant = system(android.R.color.system_accent3_700),
	)
}

private fun hueAndChroma(@ColorInt color: Int): Pair<Float, Float> {
	val hct = FloatArray(3)
	ColorUtils.colorToM3HCT(color, hct)
	return hct[0] to hct[1]
}

private const val GRAY = 6f
private const val SAME_HUE = 30f
