package dev.hloth.nativenote.support

import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher

fun hasHint(text: String) = SemanticsMatcher.expectValue(SemanticsProperties.HintText, text)
