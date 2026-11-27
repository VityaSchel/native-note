package dev.hloth.nativenote.support;

import androidx.compose.ui.autofill.AutofillManager;

public final class RecordingAutofillManager extends AutofillManager {
	public int cancels;
	public int commits;

	@Override
	public void commit() {
		commits++;
	}

	@Override
	public void cancel() {
		cancels++;
	}
}
