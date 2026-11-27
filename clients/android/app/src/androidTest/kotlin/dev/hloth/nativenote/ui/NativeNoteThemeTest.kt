package dev.hloth.nativenote.ui

import android.app.UiModeManager
import android.content.Context
import android.content.ContextWrapper
import android.content.res.Configuration
import android.content.res.Resources
import android.os.Build
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.test.DarkMode
import androidx.compose.ui.test.DeviceConfigurationOverride
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.core.graphics.ColorUtils
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeNoteThemeTest {
	@get:Rule
	val compose = createComposeRule()

	private val context = InstrumentationRegistry.getInstrumentation().targetContext

	@Test
	fun lightAppearanceTakesEveryColorFromTheSystem() {
		assertEquals(systemColorScheme(contextIn(isDark = false), dark = false).toString(), appliedScheme(isDark = false).toString())
	}

	@Test
	fun darkAppearanceTakesEveryColorFromTheSystem() {
		assertEquals(systemColorScheme(contextIn(isDark = true), dark = true).toString(), appliedScheme(isDark = true).toString())
	}

	@Test
	fun theAccentIsTheOneOfTheSystemPalette() {
		for (dark in listOf(false, true)) {
			val context = contextIn(dark)
			val accent = context.getColor(if (dark) android.R.color.system_accent1_200 else android.R.color.system_accent1_600)

			assertTrue(followsPalette(systemColorScheme(context, dark).primary.toArgb(), accent))
		}
	}

	@Test
	fun rolesThatFollowThePaletteAreKeptWithTheirContrastLevel() {
		for (dark in listOf(false, true)) {
			val context = contextIn(dark)
			val roles = if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
			val accent = context.getColor(if (dark) android.R.color.system_accent1_200 else android.R.color.system_accent1_600)
			assumeTrue("these roles contradict the palette", followsPalette(roles.primary.toArgb(), accent))

			assertEquals(roles.toString(), systemColorScheme(context, dark).toString())
		}
	}

	@Test
	fun rolesThatContradictThePaletteGiveWayToIt() {
		val samsungBlue = 0xFF387AFF.toInt()
		val coral = 0xFFAE301F.toInt()

		assertFalse(followsPalette(samsungBlue, coral))
		assertTrue(followsPalette(0xFF8F4C38.toInt(), coral))
		assertTrue(followsPalette(0xFFB02F3C.toInt(), 0xFFAE301F.toInt()))
		assertTrue(followsPalette(0xFF5E5E5E.toInt(), 0xFF606060.toInt()))
		assertFalse(followsPalette(samsungBlue, 0xFF606060.toInt()))
	}

	@Test
	fun aPaletteTheRolesContradictColorsTheWholeScheme() {
		assumeTrue("a raised contrast keeps the roles", Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && context.getSystemService(UiModeManager::class.java).contrast <= 0)
		for (dark in listOf(false, true)) {
			val roles = if (dark) dynamicDarkColorScheme(contextIn(dark)) else dynamicLightColorScheme(contextIn(dark))
			val opposite = FloatArray(3).let { hct ->
				ColorUtils.colorToM3HCT(roles.primary.toArgb(), hct)
				ColorUtils.M3HCTToColor((hct[0] + 180) % 360, 48f, 50f)
			}
			val recolored = recolored(contextIn(dark), setOf(android.R.color.system_accent1_200, android.R.color.system_accent1_600), opposite)

			val scheme = systemColorScheme(recolored, dark)

			assertEquals(PaletteColors(recolored::getColor).scheme(dark).toString(), scheme.toString())
			assertEquals(Color(opposite), scheme.primary)
		}
	}

	@Test
	fun thePaletteSchemeIsTheOneComposeBuildsFromThePalette() {
		val compose = Class.forName("androidx.compose.material3.DynamicTonalPaletteKt")
		val palette = compose.getDeclaredMethod("dynamicTonalPalette", Context::class.java).invoke(null, context)
		for (dark in listOf(false, true)) {
			val builder = compose.declaredMethods.single { it.name == if (dark) "dynamicDarkColorScheme31" else "dynamicLightColorScheme31" }
			val expected = builder.apply { isAccessible = true }.invoke(null, palette) as ColorScheme

			val ours = PaletteColors(context::getColor).scheme(dark)
			assertEquals(colors(expected).keys, colors(ours).keys)
			assertTrue("${colors(expected).size} roles", colors(expected).size >= 45)
			for ((role, color) in colors(expected)) assertTrue("$role $dark ${color} ${colors(ours)[role]}", near(color, colors(ours).getValue(role)))
		}
	}

	private fun colors(scheme: ColorScheme): Map<String, Color> =
		scheme.toString().substringAfter("ColorScheme(").removeSuffix(")").let { Regex("(\\w+)=Color\\(([^)]*)\\)").findAll(it) }
			.associate { match ->
				val (r, g, b, a) = match.groupValues[2].split(", ").map { it.toFloatOrNull() ?: 1f }
				match.groupValues[1] to Color(r, g, b, a)
			}

	private fun near(first: Color, second: Color) = listOf(first.red - second.red, first.green - second.green, first.blue - second.blue).all { abs(it) < 0.01f }

	private fun contextIn(isDark: Boolean): Context {
		val configuration = Configuration(context.resources.configuration)
		val night = if (isDark) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
		configuration.uiMode = configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK.inv() or night
		return context.createConfigurationContext(configuration)
	}

	@Suppress("DEPRECATION")
	private fun recolored(base: Context, ids: Set<Int>, color: Int): Context {
		val resources = object : Resources(base.resources.assets, base.resources.displayMetrics, base.resources.configuration) {
			override fun getColor(id: Int, theme: Theme?) = if (id in ids) color else base.resources.getColor(id, theme)
		}
		return object : ContextWrapper(base) {
			override fun getResources() = resources
		}
	}

	private fun appliedScheme(isDark: Boolean): ColorScheme {
		lateinit var applied: ColorScheme
		compose.setContent {
			DeviceConfigurationOverride(DeviceConfigurationOverride.DarkMode(isDark)) {
				NativeNoteTheme { applied = MaterialTheme.colorScheme }
			}
		}
		compose.waitForIdle()
		return applied
	}
}
