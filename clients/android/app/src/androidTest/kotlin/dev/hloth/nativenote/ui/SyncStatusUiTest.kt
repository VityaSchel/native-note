package dev.hloth.nativenote.ui

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.R
import dev.hloth.nativenote.crypto.AesGcm
import dev.hloth.nativenote.model.SyncStatus
import dev.hloth.nativenote.storage.NoteStore
import dev.hloth.nativenote.storage.SQLiteConnection
import dev.hloth.nativenote.storage.enableSync
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.support.onMain
import dev.hloth.nativenote.sync.SyncSettings
import dev.hloth.nativenote.sync.SyncTransport
import dev.hloth.nativenote.unlock.LibraryFiles
import dev.hloth.nativenote.unlock.UnlockKeys
import java.io.IOException
import org.junit.Assert.assertEquals
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
		compose.setContent { NativeNoteTheme { LibraryScreen(model, onSettings = {}) } }

		compose.waitUntil(10_000) { model.syncStatus.phase is SyncStatus.Phase.Failed }
		compose.onNodeWithContentDescription(text(R.string.sync_stopped)).performClick()
		compose.onNode(hasText(context.getString(R.string.sync_unreachable, "connection refused")) and hasAnyAncestor(isDialog())).assertIsDisplayed()
		val before = attempts
		compose.onNode(hasText(text(R.string.try_again)) and hasAnyAncestor(isDialog())).performClick()

		compose.waitUntil(10_000) { attempts > before && model.syncStatus.phase is SyncStatus.Phase.Failed }
		assertEquals(0, compose.onAllNodes(isDialog()).fetchSemanticsNodes().size)
	}
}
