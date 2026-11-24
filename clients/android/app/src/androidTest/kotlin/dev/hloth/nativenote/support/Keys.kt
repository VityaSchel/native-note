package dev.hloth.nativenote.support

import android.view.KeyEvent
import androidx.test.platform.app.InstrumentationRegistry

fun pressBack() = InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
