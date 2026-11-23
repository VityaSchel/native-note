package dev.hloth.nativenote.ui

import android.content.Context
import android.content.res.Configuration
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.ui.test.DarkMode
import androidx.compose.ui.test.DeviceConfigurationOverride
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeNoteThemeTest {
	@get:Rule
	val compose = createComposeRule()

	private val context = InstrumentationRegistry.getInstrumentation().targetContext

	@Test
	fun lightAppearanceTakesEveryColorFromTheSystemLightScheme() {
		assertEquals(dynamicLightColorScheme(contextIn(isDark = false)).toString(), appliedScheme(isDark = false).toString())
	}

	@Test
	fun darkAppearanceTakesEveryColorFromTheSystemDarkScheme() {
		assertEquals(dynamicDarkColorScheme(contextIn(isDark = true)).toString(), appliedScheme(isDark = true).toString())
	}

	private fun contextIn(isDark: Boolean): Context {
		val configuration = Configuration(context.resources.configuration)
		val night = if (isDark) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
		configuration.uiMode = configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK.inv() or night
		return context.createConfigurationContext(configuration)
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
