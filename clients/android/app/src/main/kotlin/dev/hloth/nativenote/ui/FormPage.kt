package dev.hloth.nativenote.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

@Composable
fun FormPage(
	pane: String,
	title: String,
	icon: Int,
	subtitle: String? = null,
	actions: @Composable RowScope.() -> Unit,
	content: @Composable ColumnScope.() -> Unit = {},
) {
	Box(Modifier.fillMaxSize().semantics { paneTitle = pane }.safeDrawingPadding().imePadding()) {
		FormColumn(title, subtitle, Modifier.padding(24.dp), actions, icon = icon, content = content)
	}
}

@Composable
fun FormColumn(
	title: String,
	subtitle: String?,
	modifier: Modifier,
	actions: @Composable RowScope.() -> Unit,
	icon: Int? = null,
	content: @Composable ColumnScope.() -> Unit,
) {
	BoxWithConstraints(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
		val pinsActions = maxHeight >= ROOM_FOR_PINNED_ACTIONS
		val scroll = rememberScrollState()
		Column(Modifier.widthIn(max = 560.dp).fillMaxSize().then(if (pinsActions) Modifier else Modifier.verticalScroll(scroll)).then(modifier)) {
			Column(
				if (pinsActions) Modifier.weight(1f).verticalScroll(scroll) else Modifier,
				verticalArrangement = Arrangement.spacedBy(16.dp),
			) {
				icon?.let { Icon(painterResource(it), contentDescription = null, Modifier.size(40.dp), tint = MaterialTheme.colorScheme.primary) }
				Text(title, Modifier.semantics { heading() }, style = MaterialTheme.typography.headlineMedium)
				subtitle?.let { Text(it, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant) }
				if (icon != null) Spacer(Modifier.size(8.dp))
				content()
			}
			FormActions(actions)
		}
	}
}

@Composable
private fun FormActions(actions: @Composable RowScope.() -> Unit) {
	FlowRow(
		Modifier.fillMaxWidth().padding(top = 16.dp),
		horizontalArrangement = Arrangement.End,
		itemVerticalAlignment = Alignment.CenterVertically,
	) { actions() }
}

private val ROOM_FOR_PINNED_ACTIONS = 320.dp
