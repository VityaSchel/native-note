package dev.hloth.nativenote.ui

import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.Composable
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.R
import dev.hloth.nativenote.crypto.AesGcm
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.model.SyncStatus
import dev.hloth.nativenote.storage.NoteStore
import dev.hloth.nativenote.storage.SQLiteConnection
import dev.hloth.nativenote.storage.enableSync
import dev.hloth.nativenote.support.WithoutKeyboard
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.support.onMain
import dev.hloth.nativenote.sync.SyncSettings
import dev.hloth.nativenote.sync.SyncTransport
import dev.hloth.nativenote.unlock.LibraryFiles
import dev.hloth.nativenote.unlock.UnlockKeys
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.awaitCancellation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SyncStatusUiTest {
	@get:Rule
	val folder = TemporaryFolder()

	@get:Rule
	val compose = createComposeRule()

	private val context = InstrumentationRegistry.getInstrumentation().targetContext

	private fun text(id: Int) = context.getString(id)

	private fun setContent(content: @Composable () -> Unit) = compose.setContent { WithoutKeyboard(content) }

	@Test
	fun aFailedSyncShowsWhyAndTriesAgain() {
		val password = "correct horse"
		val files = LibraryFiles(folder.root)
		var attempts = 0
		val model = appModel(folder.root, makeTransport = {
			SyncTransport {
				attempts++
				throw IOException("connection refused")
			}
		})
		model.await { start() }
		model.await { setUp(password) }
		onMain { model.finishOnboarding() }
		model.await { lock() }
		SQLiteConnection(files.database, UnlockKeys.databaseKey(password, files.record.read()!!), create = false).use {
			NoteStore(it).enableSync(SyncSettings("http://127.0.0.1:9/", AesGcm.randomBytes(32), AesGcm.randomBytes(32)), 0u)
		}
		model.await { unlock(password) }
		setContent { NativeNoteTheme { LibraryScreen(model, onSettings = {}) } }

		compose.waitUntil(10_000) { model.syncStatus.phase is SyncStatus.Phase.Failed }
		compose.onNodeWithContentDescription(text(R.string.sync_stopped)).performClick()
		compose.onNode(hasText(context.getString(R.string.sync_unreachable, "connection refused")) and hasAnyAncestor(isDialog())).assertIsDisplayed()
		val before = attempts
		compose.onNode(hasText(text(R.string.try_again)) and hasAnyAncestor(isDialog())).performClick()

		compose.waitUntil(10_000) { attempts > before && model.syncStatus.phase is SyncStatus.Phase.Failed }
		assertEquals(0, compose.onAllNodes(isDialog()).fetchSemanticsNodes().size)
	}

	@Test
	fun aRetryKeepsTheStoppedIconAndItsDialogOpen() {
		var hangs = false
		val model = syncedOver {
			if (hangs) awaitCancellation()
			throw IOException("connection refused")
		}
		setContent { NativeNoteTheme { LibraryScreen(model, onSettings = {}) } }
		compose.waitUntil(10_000) { model.syncStatus.phase is SyncStatus.Phase.Failed }
		val icon = compose.onNodeWithContentDescription(text(R.string.sync_stopped))
		assertEquals(LiveRegionMode.Polite, icon.fetchSemanticsNode().config[SemanticsProperties.LiveRegion])
		icon.performClick()

		hangs = true
		onMain { model.syncNow() }
		compose.waitUntil(10_000) { model.syncStatus.phase == SyncStatus.Phase.Syncing }

		compose.onNode(hasText(text(R.string.sync_stopped)) and hasAnyAncestor(isDialog())).assertIsDisplayed()
	}

	@Test
	fun syncNowInSettingsSaysHowItEnded() {
		val model = syncedOver { throw IOException("connection refused") }
		setContent { NativeNoteTheme { SettingsScreen(onBack = {}, onChangePassword = { _, _ -> null }, sync = { SyncSettingsSection(model, onSetUp = {}) }) } }
		compose.waitUntil(10_000) { model.syncStatus.phase is SyncStatus.Phase.Failed }
		val outcome = "${text(R.string.sync_stopped)}. ${context.getString(R.string.sync_unreachable, "connection refused")}"
		val status = compose.onNodeWithText(outcome, useUnmergedTree = true)
		assertFalse(SemanticsProperties.LiveRegion in status.fetchSemanticsNode().config)

		val before = attempts
		compose.onNodeWithText(text(R.string.sync_now)).performClick()
		compose.waitUntil(10_000) { attempts > before && model.syncStatus.phase is SyncStatus.Phase.Failed }
		assertEquals(LiveRegionMode.Polite, status.fetchSemanticsNode().config[SemanticsProperties.LiveRegion])
	}

	@Test
	fun aSyncStartedAndStoppedInOneBreathDoesNotHangTheNextUnlock() {
		val model = syncedOver { throw IOException("connection refused") }

		val main = Handler(Looper.getMainLooper())
		waitFor { model.syncStatus.phase is SyncStatus.Phase.Failed }
		onMain {
			model.syncNow()
			main.post { model.lock() }
		}
		waitFor { model.phase == AppModel.Phase.Locked }
		main.post { model.unlock(password) }

		waitFor { model.syncStatus.phase is SyncStatus.Phase.Failed }
	}

	@Test
	fun theStoppedIconIsAnnouncedOnceNotOnEveryReturnToTheList() {
		val model = syncedOver { throw IOException("connection refused") }
		setContent { NativeNoteTheme { LibraryScreen(model, onSettings = {}) } }
		compose.waitUntil(10_000) { model.syncStatus.phase is SyncStatus.Phase.Failed }
		val icon = compose.onNodeWithContentDescription(text(R.string.sync_stopped))
		assertEquals(LiveRegionMode.Polite, icon.fetchSemanticsNode().config[SemanticsProperties.LiveRegion])

		compose.onNodeWithContentDescription(text(R.string.new_note)).performClick()
		compose.waitUntil(10_000) { model.selection != null }
		compose.onNodeWithContentDescription(text(R.string.back)).performClick()
		compose.waitUntil(10_000) { compose.onAllNodes(hasText(text(R.string.no_notes))).fetchSemanticsNodes().isNotEmpty() }

		assertFalse(SemanticsProperties.LiveRegion in icon.fetchSemanticsNode().config)
	}

	private val password = "correct horse"
	private var attempts = 0

	private fun waitFor(condition: () -> Boolean) {
		val deadline = System.nanoTime() + 10_000_000_000
		val held = AtomicBoolean()
		while (!held.get()) {
			val answered = CountDownLatch(1)
			Handler(Looper.getMainLooper()).post {
				held.set(condition())
				answered.countDown()
			}
			assertTrue("the main thread stopped answering", answered.await(5, TimeUnit.SECONDS))
			assertTrue("the condition never held", System.nanoTime() < deadline)
			Thread.sleep(20)
		}
	}

	private fun syncedOver(exchange: suspend () -> ByteArray): AppModel {
		val files = LibraryFiles(folder.root)
		val model = appModel(folder.root, makeTransport = {
			SyncTransport {
				attempts++
				exchange()
			}
		})
		model.await { start() }
		model.await { setUp(password) }
		onMain { model.finishOnboarding() }
		model.await { lock() }
		SQLiteConnection(files.database, UnlockKeys.databaseKey(password, files.record.read()!!), create = false).use {
			NoteStore(it).enableSync(SyncSettings("http://127.0.0.1:9/", AesGcm.randomBytes(32), AesGcm.randomBytes(32)), 0u)
		}
		model.await { unlock(password) }
		return model
	}
}
