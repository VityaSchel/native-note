package dev.hloth.nativenote.threatmodel

import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.hloth.nativenote.sync.HttpTransport
import dev.hloth.nativenote.sync.SyncError
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.Locale
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import kotlin.system.measureTimeMillis
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TransportHeaderTest {
	private class HeadCapture(private val reply: String) : AutoCloseable {
		private val socket = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
		val connections = AtomicInteger()
		@Volatile
		var head = ""
		val address = "http://127.0.0.1:${socket.localPort}/"
		private val accepting = thread {
			while (!socket.isClosed) {
				val client = runCatching { socket.accept() }.getOrNull() ?: break
				connections.incrementAndGet()
				client.use {
					val input = it.getInputStream()
					val read = StringBuilder()
					while (!read.endsWith("\r\n\r\n")) {
						val byte = input.read()
						if (byte < 0) break
						read.append(byte.toChar())
					}
					head = read.toString()
					it.getOutputStream().write(reply.encodeToByteArray())
					it.getOutputStream().flush()
				}
			}
		}

		override fun close() {
			socket.close()
			accepting.join(2_000)
		}
	}

	private fun refusal(capture: HeadCapture) = runCatching { runBlocking { HttpTransport(capture.address).post(ByteArray(256)) } }.exceptionOrNull()

	@Test
	fun aRequestCarriesOnlyFixedHeadersTheSameOnEveryPhone() {
		HeadCapture("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").use { capture ->
			assertEquals(404, (refusal(capture) as SyncError.Refused).status)

			val lines = capture.head.trimEnd().split("\r\n")
			assertEquals("POST / HTTP/1.1", lines.first())
			val fields = lines.drop(1).associate { line -> line.substringBefore(':').lowercase() to line.substringAfter(':').trim() }
			val fixed = HttpTransport.HEADERS.associate { (name, value) -> name.lowercase() to value }
			assertEquals("$fields", emptySet<String>(), fields.keys - fixed.keys - setOf("host", "content-length", "connection"))
			for ((name, value) in fixed) assertEquals(name, value, fields[name])
			assertEquals("256", fields["content-length"])
			assertTrue(fields["connection"]?.lowercase() in setOf(null, "keep-alive", "close"))
			for (leak in listOf("Android", "Dalvik", "okhttp", "Native%20Note", Locale.getDefault().toLanguageTag())) {
				assertFalse(leak, capture.head.contains(leak, ignoreCase = true))
			}
		}
	}

	@Test
	fun aRedirectIsReportedNotFollowed() {
		HeadCapture("HTTP/1.1 301 Moved Permanently\r\nLocation: /elsewhere\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").use { capture ->
			assertEquals(301, (refusal(capture) as SyncError.Refused).status)
			assertEquals(1, capture.connections.get())
		}
	}

	@Test
	fun aServerThatKeepsDrippingBytesIsGivenUpOnAfterTheLimit() {
		ServerSocket(0, 8, InetAddress.getByName("127.0.0.1")).use { server ->
			val dripping = thread {
				runCatching {
					server.accept().use { client ->
						val output = client.getOutputStream()
						output.write("HTTP/1.1 200 OK\r\nContent-Length: 100000\r\n\r\n".encodeToByteArray())
						while (true) {
							output.write(0)
							output.flush()
							Thread.sleep(100)
						}
					}
				}
			}
			var failure: Throwable? = null
			val elapsed = measureTimeMillis {
				failure = runCatching { runBlocking { HttpTransport("http://127.0.0.1:${server.localPort}/", limitMillis = 500).post(ByteArray(256)) } }.exceptionOrNull()
			}

			assertTrue("$failure", failure is SocketTimeoutException)
			assertTrue("$elapsed ms", elapsed < 5_000)
			dripping.join(5_000)
		}
	}

	@Test
	fun cancelingARequestThatCannotConnectReturnsAtOnce() {
		ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { full ->
			val waiting = List(4) { Socket() }
			try {
				for (socket in waiting) runCatching { socket.connect(full.localSocketAddress, 300) }
				val elapsed = measureTimeMillis {
					runBlocking {
						val request = launch { HttpTransport("http://127.0.0.1:${full.localPort}/").post(ByteArray(256)) }
						delay(500)
						request.cancelAndJoin()
					}
				}

				assertTrue("$elapsed ms", elapsed < 3_000)
			} finally {
				waiting.forEach { it.close() }
			}
		}
	}
}
