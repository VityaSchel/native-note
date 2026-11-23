package dev.hloth.nativenote.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.hintText
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.model.RecoveryPhrase
import dev.hloth.nativenote.model.SetupFailure
import dev.hloth.nativenote.model.SetupResult
import dev.hloth.nativenote.model.SetupStart
import dev.hloth.nativenote.sync.PhraseEntry
import dev.hloth.nativenote.sync.SyncError
import kotlinx.coroutines.launch

enum class SyncSetupMode { SetUp, ChangeServer, Rotate }

private sealed interface Step {
	data object Server : Step

	data object Preparing : Step

	data class Words(val phrase: RecoveryPhrase) : Step

	data class Confirm(val phrase: RecoveryPhrase) : Step

	data object Join : Step

	data object CurrentPhrase : Step
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SyncSetupScreen(model: AppModel, mode: SyncSetupMode, onDone: () -> Unit) {
	val mnemonic = model.mnemonic
	var step by remember { mutableStateOf(if (mode == SyncSetupMode.Rotate) Step.Preparing else Step.Server) }
	val server = remember { TextFieldState(model.syncStatus.server.orEmpty()) }
	val apiKey = remember { TextFieldState() }
	var phrase by remember { mutableStateOf(mnemonic?.let(::PhraseEntry)) }
	var answers by remember { mutableStateOf(List(3) { "" }) }
	var revealed by remember { mutableStateOf(false) }
	var working by remember { mutableStateOf(false) }
	var failure by remember { mutableStateOf<SetupFailure?>(null) }
	val failureInView = remember { BringIntoViewRequester() }
	LaunchedEffect(failure) { if (failure != null) failureInView.bringIntoView() }
	val scope = rememberCoroutineScope()
	val close = {
		model.cancelRecovery()
		onDone()
	}

	fun run(action: suspend () -> Unit) {
		working = true
		failure = null
		scope.launch {
			try {
				action()
			} finally {
				working = false
			}
		}
	}

	fun started(result: SetupResult<SetupStart>) {
		when (result) {
			is SetupResult.Err -> failure = result.failure
			is SetupResult.Ok -> when (val start = result.value) {
				is SetupStart.NewLibrary -> step = Step.Words(start.phrase)
				SetupStart.ExistingLibrary -> step = Step.Join
				SetupStart.Reattached -> onDone()
			}
		}
	}

	LaunchedEffect(Unit) {
		if (mode != SyncSetupMode.Rotate) return@LaunchedEffect
		when (val prepared = model.prepareRotation()) {
			is SetupResult.Ok -> step = Step.Words(prepared.value)
			is SetupResult.Err -> failure = prepared.failure
		}
	}

	val back: () -> Unit = {
		when (val current = step) {
			is Step.Confirm -> step = Step.Words(current.phrase)
			is Step.Words, Step.Join -> if (mode == SyncSetupMode.Rotate) close() else step = Step.Server
			else -> close()
		}
		failure = null
	}
	BackHandler(enabled = !working, onBack = back)

	val (title, explanation) = when (val current = step) {
		Step.Server -> stringResource(if (mode == SyncSetupMode.ChangeServer) R.string.change_server else R.string.set_up_sync) to
			(if (mode == SyncSetupMode.ChangeServer) stringResource(R.string.change_server_explanation) else null)
		Step.Preparing -> stringResource(R.string.change_recovery_phrase) to null
		is Step.Words -> stringResource(R.string.write_down_phrase) to stringResource(R.string.words_explanation)
		is Step.Confirm -> stringResource(R.string.confirm_phrase) to stringResource(R.string.confirm_explanation, current.phrase.positionsToConfirm.joinToString(", ") { "${it + 1}" })
		Step.Join -> stringResource(R.string.enter_phrase) to stringResource(R.string.join_explanation)
		Step.CurrentPhrase -> stringResource(R.string.enter_current_phrase) to stringResource(R.string.current_phrase_explanation)
	}

	val proceed: () -> Unit = {
		when (val current = step) {
			Step.Server -> run { started(model.prepareSync(server.text.toString(), apiKey.text.toString())) }
			Step.Preparing -> Unit
			is Step.Words -> step = Step.Confirm(current.phrase)
			is Step.Confirm -> run {
				val result = if (mode == SyncSetupMode.Rotate) model.finishRotation(answers) else model.finishSync(answers)
				when (result) {
					null -> onDone()
					SetupFailure.RotatedElsewhere -> step = Step.CurrentPhrase
					SetupFailure.ServerHasLibrary -> {
						failure = result
						step = Step.Join
					}
					else -> failure = result
				}
			}
			Step.Join -> phrase?.let { entry -> run { model.joinSync(server.text.toString(), apiKey.text.toString(), entry).let { if (it == null) onDone() else failure = it } } }
			Step.CurrentPhrase -> phrase?.let { entry ->
				run {
					val adopted = model.adoptCurrentPhrase(entry)
					if (adopted != null) {
						failure = adopted
					} else {
						model.finishRotation(answers).let { if (it == null) onDone() else failure = it }
					}
				}
			}
		}
	}
	val canProceed = !working && when (step) {
		Step.Server -> server.text.isNotBlank() && apiKey.text.isNotBlank()
		Step.Preparing -> false
		is Step.Words -> revealed
		is Step.Confirm -> answers.all { it.isNotBlank() }
		Step.Join, Step.CurrentPhrase -> phrase?.opens == true
	}

	Scaffold(
		topBar = {
			TopAppBar(
				title = {},
				navigationIcon = {
					IconButton(onClick = back, enabled = !working) { Icon(painterResource(R.drawable.ic_arrow_back), stringResource(R.string.back)) }
				},
			)
		},
	) { padding ->
		Box(Modifier.padding(padding).fillMaxSize().imePadding(), contentAlignment = Alignment.TopCenter) {
			Column(Modifier.widthIn(max = 560.dp).fillMaxSize().padding(horizontal = 24.dp)) {
				Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(16.dp)) {
					Text(title, style = MaterialTheme.typography.headlineMedium)
					explanation?.let { Text(it, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant) }
					failure?.let {
						Text(setupFailureMessage(it), Modifier.bringIntoViewRequester(failureInView), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
					}
					when (val current = step) {
						Step.Server -> {
							val serverLabel = stringResource(R.string.server)
							OutlinedTextField(
								server,
								Modifier.fillMaxWidth().semantics { hintText = serverLabel },
								enabled = !working,
								placeholder = { Text(stringResource(R.string.server)) },
								supportingText = { Text(stringResource(R.string.server_example)) },
								lineLimits = TextFieldLineLimits.SingleLine,
								keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false, imeAction = ImeAction.Next),
							)
							PasswordField(apiKey, stringResource(R.string.api_key), enabled = !working, onAction = { if (canProceed) proceed() })
						}
						Step.Preparing -> Unit
						is Step.Words -> RecoveryWords(current.phrase.words, revealed, onReveal = { revealed = true })
						is Step.Confirm -> current.phrase.positionsToConfirm.forEachIndexed { position, index ->
							WordField(index, answers[position], enabled = !working, modifier = Modifier.fillMaxWidth()) { text -> answers = answers.toMutableList().also { it[position] = text } }
						}
						Step.Join, Step.CurrentPhrase -> phrase?.let { entry -> PhraseFields(entry, enabled = !working) { change -> phrase = phrase?.let(change) } }
					}
				}
				Row(Modifier.fillMaxWidth().padding(vertical = 16.dp), horizontalArrangement = Arrangement.End) {
					Button(onClick = proceed, enabled = canProceed) { BusyLabel(stringResource(R.string.continue_action), working) }
				}
			}
		}
	}
}

@Composable
private fun RecoveryWords(words: List<String>, revealed: Boolean, onReveal: () -> Unit) {
	OutlinedCard(Modifier.fillMaxWidth()) {
		if (!revealed) {
			Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
				Text(stringResource(R.string.screen_watched), style = MaterialTheme.typography.bodyMedium)
				OutlinedButton(onClick = onReveal) { Text(stringResource(R.string.reveal)) }
			}
			return@OutlinedCard
		}
		Row(Modifier.fillMaxWidth().padding(16.dp)) {
			for (column in 0 until 2) {
				Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
					for (row in 0 until words.size / 2) {
						val index = column * (words.size / 2) + row
						Text("${index + 1}. ${words[index]}", style = MaterialTheme.typography.bodyLarge)
					}
				}
			}
		}
	}
}

@Composable
private fun PhraseFields(entry: PhraseEntry, enabled: Boolean, update: ((PhraseEntry) -> PhraseEntry) -> Unit) {
	val focus = remember { List(PhraseEntry.COUNT) { FocusRequester() } }
	var editing by remember { mutableIntStateOf(0) }
	Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
		for (row in 0 until PhraseEntry.COUNT / 2) {
			Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				for (index in listOf(row * 2, row * 2 + 1)) {
					WordField(
						index,
						entry.texts[index],
						enabled = enabled,
						isError = entry.isInvalid(index, editing),
						modifier = Modifier.weight(1f).focusRequester(focus[index]).onFocusChanged { state ->
							if (state.isFocused) editing = index else if (editing == index) update { it.complete(index) }
						},
					) { text ->
						var next: Int? = null
						update { latest -> latest.set(text, index).let { (changed, moved) -> changed.also { next = moved } } }
						next?.takeIf { it != index }?.let { focus[it].requestFocus() }
					}
				}
			}
		}
		when (val problem = entry.problem(editing)) {
			is PhraseEntry.Problem.UnknownWord -> Text(stringResource(R.string.unknown_word, problem.index + 1), color = MaterialTheme.colorScheme.error)
			PhraseEntry.Problem.Checksum -> Text(stringResource(R.string.phrase_checksum), color = MaterialTheme.colorScheme.error)
			null -> Unit
		}
	}
}

@Composable
private fun WordField(
	index: Int,
	text: String,
	enabled: Boolean,
	modifier: Modifier = Modifier,
	isError: Boolean = false,
	onChange: (String) -> Unit,
) {
	NoPersonalizedLearning {
		val label = stringResource(R.string.word_number, index + 1)
		OutlinedTextField(
			value = text,
			onValueChange = onChange,
			modifier = modifier.semantics { hintText = label },
			enabled = enabled,
			isError = isError,
			singleLine = true,
			leadingIcon = { Text("${index + 1}", color = MaterialTheme.colorScheme.onSurfaceVariant) },
			keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false, imeAction = ImeAction.Next),
		)
	}
}

@Composable
fun setupFailureMessage(failure: SetupFailure): String = when (failure) {
	SetupFailure.InvalidServer -> stringResource(R.string.setup_invalid_server)
	SetupFailure.InvalidApiKey -> stringResource(R.string.setup_invalid_api_key)
	is SetupFailure.Unreachable -> stringResource(R.string.sync_unreachable, failure.reason)
	SetupFailure.Refused -> stringResource(R.string.sync_refused)
	is SetupFailure.Answered -> syncFailureMessage(SyncError.Refused(failure.status))
	SetupFailure.ServerHasLibrary -> stringResource(R.string.setup_server_has_library)
	SetupFailure.ServerHoldsAnotherLibrary -> stringResource(R.string.setup_server_holds_another)
	SetupFailure.ServerHasNoLibrary -> stringResource(R.string.setup_server_has_no_library)
	SetupFailure.AlreadySetUp -> stringResource(R.string.setup_already_set_up)
	SetupFailure.NotSetUp -> stringResource(R.string.setup_not_set_up)
	SetupFailure.RotatedElsewhere -> stringResource(R.string.setup_rotated_elsewhere)
	SetupFailure.ServerBehind -> stringResource(R.string.setup_server_behind)
	SetupFailure.OutcomeUnknown -> stringResource(R.string.setup_outcome_unknown)
	SetupFailure.WordsDoNotMatch -> stringResource(R.string.setup_words_do_not_match)
	SetupFailure.PhraseDoesNotOpen -> stringResource(R.string.setup_phrase_does_not_open)
	SetupFailure.StartAgain -> stringResource(R.string.setup_start_again)
	SetupFailure.WordlistMissing -> stringResource(R.string.setup_wordlist_missing)
	is SetupFailure.Failed -> syncFailureMessage(failure.reason)
}
