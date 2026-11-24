package dev.hloth.devtools.speech;

import android.media.AudioFormat;
import android.speech.tts.SynthesisCallback;
import android.speech.tts.SynthesisRequest;
import android.speech.tts.TextToSpeech;
import android.speech.tts.TextToSpeechService;
import android.speech.tts.Voice;
import android.util.Log;
import java.util.Collections;
import java.util.List;
import java.util.Locale;

public class SpeechLog extends TextToSpeechService {
	private static final int MILLIS_PER_CHARACTER = 12;

	private volatile boolean stopped;

	@Override
	protected int onIsLanguageAvailable(String language, String country, String variant) {
		return TextToSpeech.LANG_COUNTRY_AVAILABLE;
	}

	@Override
	protected String[] onGetLanguage() {
		return new String[] { "eng", "USA", "" };
	}

	@Override
	protected int onLoadLanguage(String language, String country, String variant) {
		return TextToSpeech.LANG_COUNTRY_AVAILABLE;
	}

	@Override
	public List<Voice> onGetVoices() {
		return Collections.singletonList(new Voice("log", Locale.US, Voice.QUALITY_NORMAL, Voice.LATENCY_LOW, false, Collections.emptySet()));
	}

	@Override
	public String onGetDefaultVoiceNameFor(String language, String country, String variant) {
		return "log";
	}

	@Override
	public int onIsValidVoiceName(String name) {
		return TextToSpeech.SUCCESS;
	}

	@Override
	public int onLoadVoice(String name) {
		return TextToSpeech.SUCCESS;
	}

	@Override
	protected void onStop() {
		stopped = true;
	}

	@Override
	protected void onSynthesizeText(SynthesisRequest request, SynthesisCallback callback) {
		stopped = false;
		String text = request.getCharSequenceText().toString().replace('\n', ' ');
		callback.start(16000, AudioFormat.ENCODING_PCM_16BIT, 1);
		long until = System.currentTimeMillis() + (long) text.length() * MILLIS_PER_CHARACTER;
		byte[] silence = new byte[640];
		while (!stopped && System.currentTimeMillis() < until) {
			callback.audioAvailable(silence, 0, silence.length);
			try {
				Thread.sleep(20);
			} catch (InterruptedException interrupted) {
				break;
			}
		}
		Log.i("SpeechLog", (stopped ? "CUT " : "SAY ") + text);
		callback.done();
	}
}
