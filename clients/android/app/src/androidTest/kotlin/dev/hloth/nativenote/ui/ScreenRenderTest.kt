package dev.hloth.nativenote.ui

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.graphics.drawable.AdaptiveIconDrawable
import androidx.activity.ComponentActivity
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.focus.FocusManager
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.test.DarkMode
import androidx.compose.ui.test.DeviceConfigurationOverride
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.storage.Note
import dev.hloth.nativenote.storage.NoteStore
import dev.hloth.nativenote.storage.SQLiteConnection
import dev.hloth.nativenote.support.WithoutKeyboard
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.support.hasHint
import dev.hloth.nativenote.support.onMain
import dev.hloth.nativenote.unlock.LibraryFiles
import dev.hloth.nativenote.unlock.UnlockKeys
import java.io.File
import java.util.UUID
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ScreenRenderTest {
	@get:Rule
	val compose = createAndroidComposeRule<ComponentActivity>()

	@get:Rule
	val folder = TemporaryFolder()

	private val context = InstrumentationRegistry.getInstrumentation().targetContext
	private val renders = File(context.getExternalFilesDir(null), "renders").apply { mkdirs() }
	private var isDark by mutableStateOf(false)
	private var screen by mutableStateOf<@Composable () -> Unit>({})
	private var hosting = false
	private var focus: FocusManager? = null

	private fun show(content: @Composable () -> Unit) {
		screen = content
		if (hosting) return
		hosting = true
		compose.setContent {
			DeviceConfigurationOverride(DeviceConfigurationOverride.DarkMode(isDark)) {
				focus = LocalFocusManager.current
				WithoutKeyboard { NativeNoteTheme { Surface { key(screen) { screen() } } } }
			}
		}
	}

	private fun save(name: String, dialog: Boolean = false) {
		compose.runOnIdle { focus?.clearFocus(force = true) }
		compose.waitForIdle()
		val node = if (dialog) compose.onNode(isDialog()) else compose.onRoot()
		val file = File(renders, "$name-${if (isDark) "dark" else "light"}.png")
		file.outputStream().use { node.captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it) }
	}

	@Test
	fun rendersTheAccessScreensInBothAppearances() {
		for (dark in listOf(false, true)) {
			isDark = dark
			show { OnboardingScreen(hasSecureHardware = true, isWorking = false, onSetUp = {}) }
			save("onboarding-welcome")
			compose.onNodeWithText(context.getString(R.string.next)).performClick()
			compose.onNode(hasHint(context.getString(R.string.password))).performTextInput("correct horse")
			save("onboarding-password")

			show { OnboardingScreen(hasSecureHardware = false, isWorking = true, onSetUp = {}) }
			compose.onNodeWithText(context.getString(R.string.next)).performClick()
			save("onboarding-password-working-no-hardware")

			show { UnlockScreen(wrongPassword = true, isWorking = false, onUnlock = {}, onErase = {}, biometrics = AppModel.BiometricOffer.Button) }
			save("unlock-wrong-password-biometrics")
			var offers by mutableStateOf(false)
			show { OnboardingScreen(hasSecureHardware = true, isWorking = false, onSetUp = { offers = true }, offersBiometrics = offers) }
			compose.onNodeWithText(context.getString(R.string.next)).performClick()
			for (label in listOf(R.string.password, R.string.confirm_password)) compose.onNode(hasHint(context.getString(label))).performTextInput("correct horse")
			compose.onNodeWithText(context.getString(R.string.next)).performClick()
			save("onboarding-biometrics")
			show { SettingsScreen(onBack = {}, onChangePassword = { _, _ -> null }, biometricUnlock = true) }
			save("settings-biometrics")
			show { UnlockScreen(wrongPassword = true, isWorking = false, onUnlock = {}, onErase = {}) }
			save("unlock-wrong-password")
			compose.onNodeWithText(context.getString(R.string.forgot_password)).performClick()
			save("unlock-erase", dialog = true)

			show { SettingsScreen(onBack = {}, onChangePassword = { _, _ -> null }) }
			save("settings")
			compose.onNodeWithText(context.getString(R.string.change_password)).performClick()
			save("settings-change-password", dialog = true)
			show { LicensesScreen(onBack = {}) }
			save("licenses")
		}
	}

	@Test
	fun rendersTheLibraryInBothAppearances() {
		val model = libraryWithHistory()
		for (dark in listOf(false, true)) {
			isDark = dark
			show { LibraryScreen(model, onSettings = {}) }
			save("library")

			compose.onNodeWithText("Weekend trip").performClick()
			compose.waitUntil(10_000) { model.selection != null }
			save("editor")
			onMain { model.select(null) }
			compose.waitUntil(10_000) { compose.onAllNodes(hasText("Weekend trip")).fetchSemanticsNodes().size == 1 }

			compose.onNodeWithContentDescription(context.getString(R.string.search)).performClick()
			compose.onNode(hasSetTextAction()).performTextInput("kayak")
			compose.waitUntil(10_000) { compose.onAllNodes(hasText(context.getString(R.string.results))).fetchSemanticsNodes().isNotEmpty() }
			save("library-search")
			compose.onNodeWithContentDescription(context.getString(R.string.back)).performClick()

			show { SettingsScreen(onBack = {}, onChangePassword = { _, _ -> null }, biometricUnlock = false, exchange = { LibraryExchange(model) }) }
			save("settings-notes")
			compose.onNodeWithText(context.getString(R.string.export_notes)).performClick()
			save("export", dialog = true)
		}
		onMain { model.lock() }
	}

	@Test
	fun rendersTheLibraryInTwoPanesWhenWide() {
		val model = libraryWithHistory()
		compose.runOnUiThread { compose.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
		compose.waitUntil(10_000) { compose.activity.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE }
		try {
			for (dark in listOf(false, true)) {
				isDark = dark
				show { LibraryScreen(model, onSettings = {}) }
				save("library-wide-empty")
				compose.onNodeWithText("Groceries").performClick()
				compose.waitUntil(10_000) { model.selection != null }
				save("library-wide")
				onMain { model.select(null) }
			}
		} finally {
			compose.runOnUiThread { compose.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED }
			onMain { model.lock() }
		}
	}

	@Test
	fun rendersTheLauncherIconMaskedAndThemed() {
		val icon = context.packageManager.getApplicationIcon(context.packageName) as AdaptiveIconDrawable
		val size = 432
		val layers = Rect(-size / 4, -size / 4, size * 5 / 4, size * 5 / 4)
		fun render(name: String, draw: (Canvas) -> Unit) {
			val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
			draw(Canvas(bitmap))
			File(renders, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
		}
		icon.setBounds(0, 0, size, size)

		render("icon-masked") { icon.draw(it) }
		render("icon-layers") { canvas ->
			for (layer in listOf(icon.background, icon.foreground)) {
				layer.bounds = Rect(0, 0, size, size)
				layer.draw(canvas)
			}
		}
		for ((name, colors) in mapOf(
			"icon-themed-light" to (android.R.color.system_accent1_100 to android.R.color.system_accent1_700),
			"icon-themed-dark" to (android.R.color.system_neutral1_800 to android.R.color.system_accent1_200),
		)) {
			render(name) { canvas ->
				canvas.clipPath(icon.iconMask)
				canvas.drawColor(context.getColor(colors.first))
				icon.monochrome!!.mutate().apply {
					bounds = layers
					setTint(context.getColor(colors.second))
					draw(canvas)
				}
			}
		}
	}

	private fun libraryWithHistory(): AppModel {
		val password = "correct horse"
		val model = appModel(folder.root)
		model.await { start() }
		model.await { setUp(password) }
		val day = 86_400_000L
		val now = System.currentTimeMillis()
		val history = listOf(
			"Weekend trip\nPack the kayak, the tent and two sleeping bags. Leave by eight." to now - 60_000,
			"Groceries\nOat milk, eggs, coffee beans, lemons" to now - 3_600_000,
			"Book club\nFinish chapters 7 to 9 before Thursday." to now - day,
			"Server notes\nRotate the API key after the upgrade." to now - 3 * day,
			"" to now - 4 * day,
			"Gift ideas\nA fountain pen, the hiking guide, a good scarf" to now - 40 * day,
			"Recipes\nShakshuka: peppers, tomatoes, cumin, eggs" to now - 75 * day,
			"Tax documents\nReceipts are in the blue folder." to now - 400 * day,
		)
		val files = LibraryFiles(folder.root)
		SQLiteConnection(files.database, UnlockKeys.databaseKey(password, files.record.read()!!), create = false).use { connection ->
			val store = NoteStore(connection)
			for ((body, moment) in history) store.save(Note(UUID.randomUUID(), body, moment, moment, dirty = true))
		}
		model.await { lock() }
		model.await { unlock(password) }
		return model
	}
}
