package dev.hloth.nativenote

import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.content.pm.PackageManager
import android.hardware.biometrics.BiometricManager
import android.os.Build
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.sync.Mnemonic
import dev.hloth.nativenote.unlock.KeystoreBiometricVault
import dev.hloth.nativenote.unlock.LibraryFiles

class NativeNoteApplication : Application() {
	val model: AppModel by lazy {
		val strongBox = packageManager.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)
		AppModel(
			files = LibraryFiles(noBackupFilesDir),
			hasSecureHardware = packageManager.hasSystemFeature(PackageManager.FEATURE_HARDWARE_KEYSTORE),
			makeParameters = AppModel.parameters(strongBox),
			biometricVault = KeystoreBiometricVault(noBackupFilesDir.resolve(KeystoreBiometricVault.FILE_NAME), strongBox),
			loadMnemonic = { runCatching { Mnemonic(assets.open("english.txt").use { it.readBytes() }) }.getOrNull() },
			biometricsAvailable = {
				getSystemService(BiometricManager::class.java).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) == BiometricManager.BIOMETRIC_SUCCESS
			},
		).also { it.start() }
	}

	override fun onCreate() {
		super.onCreate()
		val screenOff = object : BroadcastReceiver() {
			override fun onReceive(context: Context, intent: Intent) = model.screenTurnedOff()
		}
		val filter = IntentFilter(Intent.ACTION_SCREEN_OFF)
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) registerReceiver(screenOff, filter, RECEIVER_NOT_EXPORTED) else registerReceiver(screenOff, filter)
		getSystemService(ShortcutManager::class.java).dynamicShortcuts = listOf(
			ShortcutInfo.Builder(this, NEW_NOTE_SHORTCUT)
				.setShortLabel(getString(R.string.new_note))
				.setIcon(Icon.createWithResource(this, R.drawable.ic_shortcut_new_note))
				.setIntent(Intent(this, MainActivity::class.java).setAction(MainActivity.ACTION_NEW_NOTE).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP))
				.build(),
		)
	}

	private companion object {
		const val NEW_NOTE_SHORTCUT = "new-note"
	}
}
