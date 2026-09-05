package ai.oriveo.community.core.provider

import androidx.test.ext.junit.runners.AndroidJUnit4
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.transport.TransportRegistry
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LocalHttpReleaseSocketTest {
    @Test
    fun authNoneUsesReleaseCleartextPolicyAndProductionRequestBuilder() = runBlocking {
        val server = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        val recorded = ArrayBlockingQueue<String>(1)
        val worker = thread(name = "local-http-release-socket") {
            server.accept().use { socket ->
                val input = socket.getInputStream().bufferedReader()
                val lines = mutableListOf<String>()
                var contentLength = 0
                while (true) {
                    val line = input.readLine() ?: break
                    if (line.isEmpty()) break
                    lines += line
                    if (line.startsWith("content-length:", ignoreCase = true)) {
                        contentLength = line.substringAfter(':').trim().toInt()
                    }
                }
                val body = CharArray(contentLength).also { input.read(it) }.concatToString()
                recorded.put((lines + body).joinToString("\n"))
                val response = """{"choices":[{"message":{"role":"assistant","content":"ok"}}]}"""
                socket.getOutputStream().write(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${response.toByteArray().size}\r\nConnection: close\r\n\r\n$response".toByteArray(),
                )
            }
        }

        val json = Json { ignoreUnknownKeys = true }
        val client = HttpClient(OkHttp) { expectSuccess = false }
        val service = RelayService(client, json, TransportRegistry(json))
        val base = "http://127.0.0.1:${server.localPort}/v1"
        service.pingRelay(
            apiKey = "",
            baseUrl = base,
            modelID = "fixture-model",
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.OpenAIChatCompletions,
                authMode = RelayAuthMode.None,
                securityMode = RelayConnectionSecurityMode.LocalHttp,
                resolvedAPIBaseURL = base,
                stream = false,
            ),
        )

        val request = recorded.poll(5, TimeUnit.SECONDS) ?: error("request_not_recorded")
        assertFalse(request.contains("authorization:", ignoreCase = true))
        assertFalse(request.contains("api-key:", ignoreCase = true))
        assertFalse(request.contains("x-api-key:", ignoreCase = true))
        assertTrue(request.contains("\"model\":\"fixture-model\""))
        assertTrue(request.contains("\"max_tokens\":1"))
        client.close()
        server.close()
        worker.join(5_000)
    }
}
