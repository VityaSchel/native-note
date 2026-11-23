package dev.hloth.nativenote.conformance

import dev.hloth.nativenote.sync.Mnemonic
import dev.hloth.nativenote.sync.RecoveryBlob
import dev.hloth.nativenote.sync.Request
import dev.hloth.nativenote.sync.Response
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class RecoveryVectorTest {
	@Test
	fun recoveryBlobsSealExactlyAndOpenOnlyToAThirtyTwoByteKeyUnderTheirOwnRecoveryKey() {
		val mnemonic = Mnemonic(VectorFiles.wordlist())
		val vectors = Vectors.load(VectorFile.Recovery).filter { it.has("blob") }
		assertEquals(3, vectors.size)
		for (vector in vectors) {
			val blob = vector.bytes("blob")
			val opened = RecoveryBlob.open(blob, vector.bytes("recoveryKey"))
			assertEquals(vector.name, vector.bool("opens"), opened != null)
			if (vector.name != "blob") continue
			val contentKey = vector.bytes("contentKey")
			assertArrayEquals(contentKey, opened)
			assertArrayEquals(blob, RecoveryBlob.seal(contentKey, vector.bytes("recoveryKey"), vector.bytes("nonce")))
			assertEquals(vector.string("mnemonic").split(' '), mnemonic.words(vector.bytes("recoveryKey")))
		}
	}

	@Test
	fun eachRecoveryExchangeReEncodesAndItsBlobOpensOnlyUnderTheKeyThatSealedIt() {
		val exchanges = Vectors.load(VectorFile.Recovery).filter { it.has("request") }
		assertEquals(8, exchanges.size)
		for (exchange in exchanges) {
			val request = exchange.bytes("request")
			val response = Response.decode(exchange.bytes("response"))
			when (val decoded = RequestDecoding.decode(request)) {
				Request.Get -> {
					assertArrayEquals(exchange.name, request, Request.Get.encoded())
					val get = response as Response.Get
					assertEquals(exchange.name, get.v == 0u, get.blob.isEmpty())
					exchange.bool("opens")?.let { opens ->
						assertEquals(exchange.name, opens, RecoveryBlob.open(get.blob, exchange.bytes("recoveryKey")) != null)
					}
				}
				is Request.Put -> {
					val blob = RecoveryBlob.seal(exchange.bytes("contentKey"), exchange.bytes("recoveryKey"), exchange.bytes("nonce"))
					assertArrayEquals(exchange.name, request, Request.Put(decoded.v, blob).encoded())
					assertTrue("${exchange.name} got no put response", response is Response.Put)
				}
				is Request.Sync -> fail("${exchange.name} is a sync")
			}
		}
	}
}
