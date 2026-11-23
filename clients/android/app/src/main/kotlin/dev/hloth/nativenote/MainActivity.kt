package dev.hloth.nativenote

import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import dev.hloth.nativenote.ui.NativeNoteApp
import dev.hloth.nativenote.ui.NativeNoteTheme

class MainActivity : ComponentActivity() {
	companion object {
		const val ACTION_NEW_NOTE = "dev.hloth.nativenote.action.NEW_NOTE"

		fun sharedText(intent: Intent): String? {
			if (intent.type?.startsWith("text/") != true) return null
			val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
			val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)?.takeIf { it.isNotBlank() && text?.contains(it) != true }
			return listOfNotNull(subject, text).joinToString("\n").ifEmpty { null }
		}
	}

	private val model get() = (application as NativeNoteApplication).model

	override fun onCreate(savedInstanceState: Bundle?) {
		super.onCreate(savedInstanceState)
		enableEdgeToEdge()
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) setRecentsScreenshotEnabled(false)
		setContent {
			NativeNoteTheme {
				NativeNoteApp(model)
			}
		}
		if (savedInstanceState == null) handle(intent)
	}

	override fun onNewIntent(intent: Intent) {
		super.onNewIntent(intent)
		handle(intent)
	}

	private fun handle(intent: Intent) {
		when (intent.action) {
			ACTION_NEW_NOTE -> model.requestNote("")
			Intent.ACTION_SEND -> sharedText(intent)?.let(model::requestNote)
		}
	}

	override fun onStart() {
		super.onStart()
		model.appStarted()
	}

	override fun onStop() {
		super.onStop()
		if (!isChangingConfigurations) model.appStopped()
	}
}
