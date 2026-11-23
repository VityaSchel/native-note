package dev.hloth.nativenote.support

import kotlin.random.Random

object RealisticCorpus {
	private val titles = listOf(
		"Shopping", "Trip to Lisbon", "Meeting notes 2026-09-24", "Ideas", "買い物リスト", "ملاحظات الاجتماع",
		"Rezept: Käsespätzle", "TODO: fix / refactor", "CON", ".hidden", "a:b\\c", "🎉 Party 👨‍👩‍👧‍👦", "Café", "Café",
		"Books to read", "Passwords? No.", "Встреча с командой", "שיעורי בית", "Plan", "Plan", "PLAN",
		"Very long title ".repeat(24),
	)

	private val words = listOf(
		"the", "note", "quartz", "bread", "ferry", "meeting", "draft", "sync", "Lisbon", "kettle", "idea", "later",
		"日本語", "テキスト", "مرحبا", "العالم", "Grüße", "naïve", "façade", "😀", "👍🏽", "🇵🇹", "résumé", "Ω", "∑",
	)

	fun bodies(count: Int, seed: Long = 0x5EED): List<String> {
		val random = Random(seed)
		return List(count) { body(it, random) }
	}

	private fun body(index: Int, random: Random): String {
		val title = titles[index % titles.size]
		return when (index % 12) {
			0 -> ""
			1 -> title
			2 -> "$title\n" + (1..random.nextInt(2, 13)).joinToString("\n") { "- item $it ${sentence(3, random)}" }
			3 -> "$title\r\n" + List(5) { sentence(12, random) }.joinToString("\r\n")
			4 -> "---\nid: not-front-matter\n---\n$title\n---\n${sentence(20, random)}\n"
			5 -> "$title\n```kotlin\nval value = \"\$$index\"\n\tprintln(value)\n```\n| a | b |\n|---|---|\n| 1 | 2 |"
			6 -> "$title\n" + List(random.nextInt(400, 2_501)) { sentence(14, random) }.joinToString("\n")
			7 -> "  $title  \n\n\n${sentence(8, random)}\n\n  \t\n"
			8 -> "$title\nembedded\u0000nul and \u0007 bell\n${sentence(6, random)}"
			9 -> "$title\n" + "é".repeat(200) + "\n" + "👨‍👩‍👧‍👦".repeat(50)
			else -> "$title\n" + List(random.nextInt(1, 41)) { sentence(random.nextInt(4, 21), random) }.joinToString("\n\n")
		}
	}

	private fun sentence(length: Int, random: Random) = List(length) { words.random(random) }.joinToString(" ")
}
