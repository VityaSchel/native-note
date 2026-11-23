package dev.hloth.nativenote.conformance

import dev.hloth.nativenote.sync.NoteCipher
import dev.hloth.nativenote.sync.Request
import dev.hloth.nativenote.sync.Response
import java.util.UUID
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class SyncVectorTest {
	@Test
	fun eachSyncStepSealsItsWritesExactlyAndReadsTheOutcomeItsResponseCarries() {
		var copyId: UUID? = null
		val steps = Vectors.load(VectorFile.Sync)
		assertEquals(7, steps.size)
		for (step in steps) {
			val cipher = NoteCipher(step.bytes("contentKey"))
			val request = RequestDecoding.decode(step.bytes("request")) as Request.Sync
			val writes = step.objects("writes")
			assertEquals(step.name, writes.size, request.writes.size)
			val sealed = writes.zip(request.writes).map { (write, sent) ->
				val content = content(write.getJSONObject("content"))
				if (content.id == copyId) copyId = null
				cipher.seal(content, sent.v, write.getString("writeId").hexToByteArray(), write.getString("nonce").hexToByteArray())
			}
			assertArrayEquals(step.name, step.bytes("request"), Request.Sync(request.since, sealed).encoded())
			if (step.has("copyUuid")) copyId = UUID.fromString(step.string("copyUuid"))

			val response = Response.decode(step.bytes("response")) as Response.Sync
			val outcome = step.objectOf("outcome")
			val expected = outcome.getJSONArray("results").let { results ->
				List(results.length()) { results.getJSONObject(it).let { result -> result.getString("status") to result.getLong("v").toUInt() } }
			}
			assertEquals(step.name, expected, response.results.map { it.status.name.replaceFirstChar(Char::lowercase) to it.v })
			assertEquals(step.name, outcome.getInt("changes"), response.changes.size)
			assertFalse(response.more)
			for (change in response.changes) {
				val opened = cipher.open(change)
				assertNotNull(step.name, opened)
				assertArrayEquals(step.name, cipher.blindedId(opened!!.id), change.blindedId)
			}
		}
		assertNull("the conflict copy was pushed", copyId)
	}
}
