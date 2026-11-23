package dev.hloth.nativenote.ui

import android.text.format.DateFormat
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.NoteGrouping
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.delay

@Composable
fun rememberGrouping(): NoteGrouping {
	val resources = LocalResources.current
	val locale = LocalConfiguration.current.locales[0]
	val is24Hour = DateFormat.is24HourFormat(LocalContext.current)
	val now by produceState(System.currentTimeMillis()) {
		while (true) {
			delay(MINUTE - System.currentTimeMillis() % MINUTE)
			value = System.currentTimeMillis()
		}
	}
	val words = remember(resources, locale, is24Hour) {
		NoteGrouping.Words(
			today = resources.getString(R.string.today),
			yesterday = resources.getString(R.string.yesterday),
			previousWeek = resources.getString(R.string.previous_week),
			dateAtTime = { day, time -> resources.getString(R.string.date_at_time, day, time) },
			time = DateTimeFormatter.ofPattern(DateFormat.getBestDateTimePattern(locale, if (is24Hour) "Hm" else "hm"), locale),
			locale = locale,
		)
	}
	return remember(now, words) { NoteGrouping(now, ZoneId.systemDefault(), words) }
}

private const val MINUTE = 60_000L
