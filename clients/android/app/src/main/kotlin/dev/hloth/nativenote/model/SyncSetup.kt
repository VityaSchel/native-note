package dev.hloth.nativenote.model

data class RecoveryPhrase(val words: List<String>, val positionsToConfirm: List<Int>)

sealed interface SetupStart {
	data class NewLibrary(val phrase: RecoveryPhrase) : SetupStart

	data object ExistingLibrary : SetupStart

	data object Reattached : SetupStart
}

sealed interface SetupFailure {
	data object InvalidServer : SetupFailure

	data object InvalidApiKey : SetupFailure

	data class Unreachable(val reason: String) : SetupFailure

	data object Refused : SetupFailure

	data class Answered(val status: Int) : SetupFailure

	data object ServerHasLibrary : SetupFailure

	data object ServerHoldsAnotherLibrary : SetupFailure

	data object ServerHasNoLibrary : SetupFailure

	data object AlreadySetUp : SetupFailure

	data object NotSetUp : SetupFailure

	data object RotatedElsewhere : SetupFailure

	data object ServerBehind : SetupFailure

	data object OutcomeUnknown : SetupFailure

	data object WordsDoNotMatch : SetupFailure

	data object PhraseDoesNotOpen : SetupFailure

	data object StartAgain : SetupFailure

	data object WordlistMissing : SetupFailure

	data class Failed(val reason: Throwable) : SetupFailure
}

sealed interface SetupResult<out T> {
	data class Ok<T>(val value: T) : SetupResult<T>

	data class Err(val failure: SetupFailure) : SetupResult<Nothing>
}
