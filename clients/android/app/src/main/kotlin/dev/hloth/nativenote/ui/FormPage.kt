package dev.hloth.nativenote.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp

@Composable
fun FormPage(
	title: String,
	icon: Int,
	subtitle: String? = null,
	actions: @Composable RowScope.() -> Unit,
	content: @Composable ColumnScope.() -> Unit = {},
) {
	Box(Modifier.fillMaxSize().safeDrawingPadding().imePadding(), contentAlignment = Alignment.TopCenter) {
		Column(Modifier.widthIn(max = 560.dp).fillMaxSize().padding(24.dp)) {
			Column(
				Modifier.weight(1f).verticalScroll(rememberScrollState()),
				verticalArrangement = Arrangement.spacedBy(16.dp),
			) {
				Icon(painterResource(icon), contentDescription = null, Modifier.size(40.dp), tint = MaterialTheme.colorScheme.primary)
				Text(title, style = MaterialTheme.typography.headlineMedium)
				subtitle?.let { Text(it, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant) }
				Spacer(Modifier.size(8.dp))
				content()
			}
			Row(Modifier.fillMaxWidth().padding(top = 16.dp), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) { actions() }
		}
	}
}
