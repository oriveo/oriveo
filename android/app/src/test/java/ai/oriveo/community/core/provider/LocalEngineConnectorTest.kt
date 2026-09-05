package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalEngineConnectorTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `Open WebUI merges and deduplicates both catalog shapes and preserves a hinted model`() = runTest {
        val authorizationHeaders = mutableListOf<String?>()
        val client = HttpClient(MockEngine { request ->
            authorizationHeaders += request.headers[HttpHeaders.Authorization]
            respond(
                content = """{"data":[{"id":"catalog-model"}],"models":[{"name":"catalog-model"},{"name":"compat-model"}]}""",
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
            )
        })
        val relayService = mockk<RelayService>()
        coEvery { relayService.pingRelay(any(), any(), any(), any(), any()) } returns Unit
        val connector = LocalEngineConnector(client, json, relayService)

        val result = connector.connect(
            engine = LocalEngineKind.OpenWebUI,
            rawEndpoint = "https://openwebui.example",
            securityMode = RelayConnectionSecurityMode.RemoteHttps,
            modelHint = "hinted-model",
            apiKey = "openwebui-secret",
        )

        assertEquals(listOf("hinted-model", "catalog-model", "compat-model"), result.modelIds)
        assertTrue(result.runtimeMetadata.keys.containsAll(listOf("catalog-model", "compat-model")))
        assertEquals(listOf("Bearer openwebui-secret", "Bearer openwebui-secret"), authorizationHeaders)
        coVerify(exactly = 1) {
            relayService.pingRelay(
                "openwebui-secret",
                "https://openwebui.example/api",
                "hinted-model",
                match { it.engineProfile == "openwebui" },
                null,
            )
        }
    }

    @Test
    fun `Open WebUI authentication rejection is not reported as the wrong engine`() = runTest {
        val client = HttpClient(MockEngine {
            respond(
                content = """{"detail":"Invalid token"}""",
                status = HttpStatusCode.Unauthorized,
                headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
            )
        })
        val relayService = mockk<RelayService>(relaxed = true)
        val connector = LocalEngineConnector(client, json, relayService)

        val error = runCatching {
            connector.connect(
                engine = LocalEngineKind.OpenWebUI,
                rawEndpoint = "https://openwebui.example",
                securityMode = RelayConnectionSecurityMode.RemoteHttps,
                apiKey = "wrong-secret",
            )
        }.exceptionOrNull()

        assertEquals(
            LocalEngineConnectionFailure.AuthenticationRejected,
            (error as LocalEngineConnectionException).failure,
        )
        coVerify(exactly = 0) { relayService.pingRelay(any(), any(), any(), any(), any()) }
    }
}
