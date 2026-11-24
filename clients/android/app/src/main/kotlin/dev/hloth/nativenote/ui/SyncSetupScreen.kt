package dev.hloth.nativenote.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.TextFieldState
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
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.ContentDataType
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDataType
import androidx.compose.ui.semantics.error
import androidx.compose.ui.semantics.hideFromAccessibility
import androidx.compose.ui.semantics.hintText
import androidx.compose.ui.semantics.isTraversalGroup
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.model.RecoveryPhrase
import dev.hloth.nativenote.model.SetupFailure
import dev.hloth.nativenote.model.SetupResult
import dev.hloth.nativenote.model.SetupStart
import dev.hloth.nativenote.sync.PhraseEntry
import dev.hloth.nativenote.sync.SyncError
import kotlinx.coroutines.Job
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
	var running by remember { mutableStateOf<Job?>(null) }
	val working = running != null
	var failure by remember { mutableStateOf<SetupFailure?>(null) }
	val failureInView = remember { BringIntoViewRequester() }
	LaunchedEffect(failure) { if (failure != null) failureInView.bringIntoView() }
	val scope = rememberCoroutineScope()
	val close = {
		model.cancelRecovery()
		onDone()
	}

	fun run(action: suspend () -> Unit) {
		failure = null
		running = scope.launch { action() }.also { job -> job.invokeOnCompletion { if (running === job) running = null } }
	}

	fun show(phrase: RecoveryPhrase) {
		revealed = false
		answers = List(CONFIRMED_WORDS) { "" }
		step = Step.Words(phrase)
	}

	fun started(result: SetupResult<SetupStart>) {
		when (result) {
			is SetupResult.Err -> failure = result.failure
			is SetupResult.Ok -> when (val start = result.value) {
				is SetupStart.NewLibrary -> show(start.phrase)
				SetupStart.ExistingLibrary -> step = Step.Join
				SetupStart.Reattached -> onDone()
			}
		}
	}

	fun finished(result: SetupFailure?) {
		if (result == null) return onDone()
		failure = result.takeUnless { it == SetupFailure.RotatedElsewhere && step is Step.Confirm }
		when (result) {
			SetupFailure.RotatedElsewhere -> step = Step.CurrentPhrase
			SetupFailure.ServerHasLibrary -> step = Step.Join
			SetupFailure.ServerHasNoLibrary -> if (mode != SyncSetupMode.Rotate) step = Step.Server
			else -> Unit
		}
	}

	LaunchedEffect(Unit) {
		if (mode != SyncSetupMode.Rotate) return@LaunchedEffect
		when (val prepared = model.prepareRotation()) {
			is SetupResult.Ok -> show(prepared.value)
			is SetupResult.Err -> failure = prepared.failure
		}
	}

	val cancels = step == Step.Server || step == Step.Join
	val back: () -> Unit = {
		if (working) {
			if (cancels) {
				running?.cancel()
				model.cancelRecovery()
			}
		} else {
			when (val current = step) {
				is Step.Confirm -> step = Step.Words(current.phrase)
				is Step.Words, Step.Join -> if (mode == SyncSetupMode.Rotate) close() else step = Step.Server
				else -> close()
			}
			failure = null
		}
	}
	BackHandler(onBack = back)

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
			is Step.Confirm -> run { finished(if (mode == SyncSetupMode.Rotate) model.finishRotation(answers) else model.finishSync(answers)) }
			Step.Join -> phrase?.let { entry -> run { finished(model.joinSync(server.text.toString(), apiKey.text.toString(), entry)) } }
			Step.CurrentPhrase -> phrase?.let { entry -> run { finished(model.adoptCurrentPhrase(entry) ?: model.finishRotation(answers)) } }
		}
	}
	val canProceed = !working && when (step) {
		Step.Server -> server.text.isNotBlank() && apiKey.text.isNotBlank()
		Step.Preparing -> false
		is Step.Words -> revealed
		is Step.Confirm -> answers.all { it.isNotBlank() }
		Step.Join, Step.CurrentPhrase -> phrase?.opens == true
	}

	val proceedIfReady = { if (canProceed) proceed() }
	val action = when {
		step is Step.Confirm -> when (mode) {
			SyncSetupMode.SetUp -> R.string.turn_on_sync
			SyncSetupMode.Rotate -> R.string.change_phrase
			SyncSetupMode.ChangeServer -> R.string.move_library
		}
		step == Step.Join -> R.string.turn_on_sync
		else -> R.string.continue_action
	}

	Scaffold(
		modifier = Modifier.semantics { paneTitle = title },
		topBar = {
			TopAppBar(
				title = {},
				navigationIcon = {
					IconButton(onClick = back, enabled = !working || cancels) { Icon(painterResource(R.drawable.ic_arrow_back), stringResource(R.string.back)) }
				},
			)
		},
	) { padding ->
		Box(Modifier.padding(padding).consumeWindowInsets(padding).fillMaxSize().imePadding()) {
			key(step) {
				val opensOnFailure = remember { failure != null }
				FormColumn(
					title,
					explanation,
					Modifier.padding(start = 24.dp, end = 24.dp, bottom = 16.dp),
					actions = { Button(onClick = proceed, enabled = canProceed) { BusyLabel(stringResource(action), working) } },
				) {
					failure?.let {
						Text(
							setupFailureMessage(it),
							Modifier.bringIntoViewRequester(failureInView).semantics { liveRegion = LiveRegionMode.Assertive },
							color = MaterialTheme.colorScheme.error,
							style = MaterialTheme.typography.bodyMedium,
						)
					}
					when (val current = step) {
						Step.Server -> {
							ServerField(server, enabled = !working, takesFocus = !opensOnFailure)
							PasswordField(apiKey, stringResource(R.string.api_key), enabled = !working, onAction = proceedIfReady)
						}
						Step.Preparing -> Unit
						is Step.Words -> RecoveryWords(current.phrase.words, revealed, onReveal = { revealed = true })
						is Step.Confirm -> current.phrase.positionsToConfirm.forEachIndexed { position, index ->
							WordField(
								index,
								answers[position],
								enabled = !working,
								modifier = Modifier.fillMaxWidth(),
								isError = phrase?.couldBeListWord(answers[position]) == false,
								takesFocus = position == 0 && !opensOnFailure,
								onDone = proceedIfReady.takeIf { position == answers.lastIndex },
							) { text ->
								failure = null
								answers = answers.toMutableList().also { it[position] = text }
							}
						}
						Step.Join, Step.CurrentPhrase -> phrase?.let { entry ->
							PhraseFields(entry, enabled = !working, takesFocus = !opensOnFailure, onEdit = { failure = null }, onDone = proceedIfReady) { change ->
								phrase = phrase?.let(change)
							}
						}
					}
				}
			}
		}
	}
}

@Composable
private fun ServerField(server: TextFieldState, enabled: Boolean, takesFocus: Boolean) {
	val name = stringResource(R.string.server)
	val focus = remember { FocusRequester() }
	TakeFocus(focus, takesFocus)
	OutlinedTextField(
		server,
		Modifier.fillMaxWidth().focusRequester(focus).semantics { hintText = name },
		enabled = enabled,
		placeholder = { Text(name, Modifier.clearAndSetSemantics {}) },
		supportingText = { Text(stringResource(R.string.server_example)) },
		lineLimits = TextFieldLineLimits.SingleLine,
		keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false, imeAction = ImeAction.Next),
	)
}

private fun wordColumns(width: Dp, fontScale: Float) = if (width / fontScale < ROOM_FOR_TWO_WORDS) 1 else 2

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
		BoxWithConstraints(Modifier.fillMaxWidth().padding(16.dp)) {
			val firstWord = remember { FocusRequester() }
			LaunchedEffect(Unit) { firstWord.requestFocus() }
			val columns = wordColumns(maxWidth, LocalDensity.current.fontScale)
			val rows = words.size / columns
			Row {
				for (column in 0 until columns) {
					Column(Modifier.weight(1f).semantics { isTraversalGroup = true }, verticalArrangement = Arrangement.spacedBy(6.dp)) {
						for (index in column * rows until (column + 1) * rows) {
							Text(
								"${index + 1}. ${words[index]}",
								(if (index == 0) Modifier.focusRequester(firstWord) else Modifier).focusable(),
								style = MaterialTheme.typography.bodyLarge,
							)
						}
					}
				}
			}
		}
	}
}

@Composable
private fun PhraseFields(
	entry: PhraseEntry,
	enabled: Boolean,
	takesFocus: Boolean,
	onEdit: () -> Unit,
	onDone: () -> Unit,
	update: ((PhraseEntry) -> PhraseEntry) -> Unit,
) {
	val focus = remember { List(PhraseEntry.COUNT) { FocusRequester() } }
	var editing by remember { mutableIntStateOf(0) }
	BoxWithConstraints {
		val columns = wordColumns(maxWidth, LocalDensity.current.fontScale)
		Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
			FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp), maxItemsInEachRow = columns) {
				for (index in 0 until PhraseEntry.COUNT) {
					key(index) {
						WordField(
							index,
							entry.texts[index],
							enabled = enabled,
							isError = entry.isInvalid(index, editing),
							takesFocus = takesFocus && index == 0,
							onDone = onDone.takeIf { index == PhraseEntry.COUNT - 1 },
							modifier = Modifier.weight(1f).focusRequester(focus[index]).onFocusChanged { state ->
								if (state.isFocused) editing = index else if (editing == index) update { it.complete(index) }
							},
						) { text ->
							onEdit()
							var next: Int? = null
							update { latest -> latest.set(text, index).let { (changed, moved) -> changed.also { next = moved } } }
							next?.takeIf { it != index }?.let { focus[it].requestFocus() }
						}
					}
				}
			}
			if (entry.problem(editing) == PhraseEntry.Problem.Checksum) {
				val inView = remember { BringIntoViewRequester() }
				LaunchedEffect(Unit) { inView.bringIntoView() }
				Text(
					stringResource(R.string.phrase_checksum),
					Modifier.bringIntoViewRequester(inView).semantics { liveRegion = LiveRegionMode.Polite },
					color = MaterialTheme.colorScheme.error,
				)
			}
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
	takesFocus: Boolean = false,
	onDone: (() -> Unit)? = null,
	onChange: (String) -> Unit,
) {
	val focus = remember { FocusRequester() }
	TakeFocus(focus, takesFocus)
	NoPersonalizedLearning {
		val label = stringResource(R.string.word_number, index + 1)
		val unknown = stringResource(R.string.unknown_word, index + 1)
		OutlinedTextField(
			value = text,
			onValueChange = onChange,
			modifier = modifier.focusRequester(focus).semantics {
				hintText = label
				contentDataType = ContentDataType.None
				if (isError) error(unknown)
			},
			enabled = enabled,
			isError = isError,
			singleLine = true,
			leadingIcon = { Text("${index + 1}", Modifier.clearAndSetSemantics {}, color = MaterialTheme.colorScheme.onSurfaceVariant) },
			supportingText = if (isError) ({ Text(stringResource(R.string.not_in_word_list), Modifier.semantics { hideFromAccessibility() }) }) else null,
			keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false, imeAction = if (onDone == null) ImeAction.Next else ImeAction.Done),
			keyboardActions = if (onDone == null) KeyboardActions.Default else KeyboardActions(onDone = { onDone() }),
		)
	}
}

private const val CONFIRMED_WORDS = 3
private val ROOM_FOR_TWO_WORDS = 290.dp

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
