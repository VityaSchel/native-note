package dev.hloth.nativenote

import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ShortcutManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class EntryPointsTest {
	private val context = InstrumentationRegistry.getInstrumentation().targetContext

	private fun share(text: String?, subject: String? = null, type: String = "text/plain") = Intent(Intent.ACTION_SEND).apply {
		this.type = type
		text?.let { putExtra(Intent.EXTRA_TEXT, it) }
		subject?.let { putExtra(Intent.EXTRA_SUBJECT, it) }
	}

	@Test
	fun sharedTextBecomesTheNoteWithItsSubjectAsTheTitle() {
		assertEquals("just text", MainActivity.sharedText(share("just text")))
		assertEquals("Page title\nhttps://example.com/page", MainActivity.sharedText(share("https://example.com/page", "Page title")))
		assertEquals("Already in the text", MainActivity.sharedText(share("Already in the text", "Already")))
		assertEquals("Subject only", MainActivity.sharedText(share(null, "Subject only")))
		assertEquals("text", MainActivity.sharedText(share("text", "   ")))
		assertNull(MainActivity.sharedText(share(null)))
		assertNull(MainActivity.sharedText(share("a picture", type = "image/png")))
	}

	@Test
	fun plainTextSharedFromAnotherAppOpensNativeNote() {
		val handlers = context.packageManager.queryIntentActivities(share("x").setPackage(context.packageName), PackageManager.MATCH_DEFAULT_ONLY)

		assertEquals(listOf(MainActivity::class.java.name), handlers.map { it.activityInfo.name })
	}

	@Test
	fun theLauncherOffersANewNoteShortcut() {
		val shortcut = context.getSystemService(ShortcutManager::class.java).dynamicShortcuts.single()

		assertEquals(context.getString(R.string.new_note), shortcut.shortLabel)
		assertEquals(MainActivity.ACTION_NEW_NOTE, shortcut.intent!!.action)
		assertEquals(MainActivity::class.java.name, shortcut.intent!!.component!!.className)
	}
}
