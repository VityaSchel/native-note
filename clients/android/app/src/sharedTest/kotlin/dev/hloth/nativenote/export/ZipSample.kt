package dev.hloth.nativenote.export

object ZipSample {
	const val MOMENT = 1_760_000_000_000L

	val entries = listOf(
		ZipEntry("Groceries.md", "---\ncreated: 2025-10-09\n---\nmilk, eggs\n".encodeToByteArray(), MOMENT),
		ZipEntry("Empty.md", ByteArray(0), MOMENT + 2_000),
		ZipEntry(
			"Journal/\u0417\u0430\u043C\u0435\u0442\u043A\u0438 \u2713 \u65E5\u672C.md",
			"na\u00EFve caf\u00E9".encodeToByteArray(),
			MOMENT + 86_400_000,
		),
	)

	fun fields(entries: List<ZipEntry>) = entries.map { Triple(it.name, it.data.toList(), it.modified) }
}
