package ai.oriveo.community.core.search

import ai.oriveo.community.core.search.SearchContractFixtures.catalogEntry
import ai.oriveo.community.core.search.SearchContractFixtures.int
import ai.oriveo.community.core.search.SearchContractFixtures.str
import java.io.File
import java.net.InetAddress
import java.nio.file.Files
import java.security.KeyStore
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test

/** Executor: golden replay, same-origin redirect following (https / LAN http), abort on cross-origin (including https -> http) and too many hops, abort on oversized responses, no request when verification fails, plaintext to public hosts refused. */
class SearchExecutorTest {
    private val golden = SearchContractFixtures.load("search-contracts/transport-golden.v1.json")
    private val catalog = SearchContractFixtures.load("search-contracts/search_catalog_contract.v1.json")
        .getValue("catalog").jsonObject
    private val loopback = InetAddress.getByName("127.0.0.1")
    private val servers = mutableListOf<MockWebServer>()

    @After
    fun tearDown() {
        servers.forEach { it.shutdown() }
    }

    private fun server(vararg responses: MockResponse): MockWebServer = MockWebServer().also { s ->
        responses.forEach(s::enqueue)
        s.start(loopback, 0)
        servers += s
    }

    private fun goldenCase(id: String): JsonObject =
        SearchContractFixtures.cases(golden, "cases").first { str(it["caseId"]) == id }

    private val executor = SearchExecutor(OkHttpClient(), { listOf("127.0.0.1") })

    private fun deepseekRequest(server: MockWebServer, key: String?, scheme: String = "http"): Pair<JsonObject, SearchHttpRequest> {
        val spec = catalogEntry(catalog, "deepseek").getValue("transport").jsonObject
        val input = goldenCase("deepseek.cn.request").getValue("input").jsonObject
        val request = SearchTransport.buildSearchRequest(
            spec,
            SearchTarget(scheme = scheme, host = "127.0.0.1", port = server.port),
            str(input["query"])!!,
            int(input["count"]),
            key,
        )
        return spec to (request as SearchHttpRequest)
    }

    @Test
    fun `golden request is sent as recorded and golden response maps to golden results`() = runBlocking {
        val normal = goldenCase("deepseek.normal")
        val s = server(MockResponse().setResponseCode(200).setBody(normal.getValue("body").toString()))
        val requestCase = goldenCase("deepseek.cn.request")
        val key = str(requestCase.getValue("input").jsonObject["key"])
        val (spec, request) = deepseekRequest(s, key)

        val outcome = executor.execute(request, spec, count = null, timeoutSec = 20, custom = false, otherServices = 0)

        val expectedRequest = requestCase.getValue("expect").jsonObject
        val recorded = s.takeRequest()
        assertEquals(str(expectedRequest["method"]), recorded.method)
        assertEquals(str(expectedRequest["url"])!!.substringAfter("api.deepseek.com"), recorded.path)
        expectedRequest.getValue("headers").jsonObject.forEach { (name, value) ->
            assertEquals(name, str(value), recorded.getHeader(name))
        }
        assertEquals(expectedRequest["body"], Json.parseToJsonElement(recorded.body.readUtf8()))
        val parsed = SearchContractFixtures.parseResultOf(normal.getValue("expect").jsonObject)
        assertEquals(SearchExecution.Results((parsed as SearchParseResult.Results).results), outcome)
    }

    /** Local self-signed certificate (generated on the fly with JDK keytool, not checked in), SAN = 127.0.0.1 / localhost. */
    private fun selfSignedTls(): Pair<SSLContext, X509TrustManager> {
        val dir = Files.createTempDirectory("search-tls").toFile().apply { deleteOnExit() }
        val keystore = File(dir, "server.p12")
        val password = "changeit"
        val process = ProcessBuilder(
            File(System.getProperty("java.home"), "bin/keytool").path,
            "-genkeypair", "-alias", "server", "-keyalg", "EC", "-groupname", "secp256r1", "-validity", "2",
            "-dname", "CN=127.0.0.1", "-ext", "SAN=ip:127.0.0.1,dns:localhost",
            "-storetype", "PKCS12", "-keystore", keystore.path, "-storepass", password, "-keypass", password,
        ).redirectErrorStream(true).start()
        val log = process.inputStream.bufferedReader().readText()
        check(process.waitFor() == 0) { "keytool failed: $log" }
        val store = KeyStore.getInstance("PKCS12").apply { keystore.inputStream().use { load(it, password.toCharArray()) } }
        keystore.delete()
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(store, password.toCharArray()) }
        val tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(store) }
        val trust = tmf.trustManagers.filterIsInstance<X509TrustManager>().first()
        return SSLContext.getInstance("TLS").apply { init(kmf.keyManagers, arrayOf(trust), null) } to trust
    }

    @Test
    fun `same origin https redirect is followed with the key and maps the final response`() = runBlocking {
        val (tls, trust) = selfSignedTls()
        val normal = goldenCase("deepseek.normal")
        val s = MockWebServer().also { servers += it }
        s.useHttps(tls.socketFactory, false)
        s.enqueue(MockResponse().setResponseCode(307).setHeader("Location", "/v2/tools/search"))
        s.enqueue(MockResponse().setResponseCode(200).setBody(normal.getValue("body").toString()))
        s.start(loopback, 0)
        val tlsExecutor = SearchExecutor(OkHttpClient.Builder().sslSocketFactory(tls.socketFactory, trust).build(), { listOf("127.0.0.1") })
        val (spec, request) = deepseekRequest(s, "sk-secret", scheme = "https")

        val outcome = tlsExecutor.execute(request, spec, count = null, timeoutSec = 20, custom = false, otherServices = 0)

        assertEquals(2, s.requestCount)
        assertEquals("/v1/tools/search", s.takeRequest().path)
        val followed = s.takeRequest()
        assertEquals("/v2/tools/search", followed.path)
        assertEquals("POST", followed.method)
        assertEquals("Bearer sk-secret", followed.getHeader("Authorization"))
        val parsed = SearchContractFixtures.parseResultOf(normal.getValue("expect").jsonObject)
        assertEquals(SearchExecution.Results((parsed as SearchParseResult.Results).results), outcome)
    }

    @Test
    fun `cross origin redirect is aborted so the key never reaches another host`() = runBlocking {
        val other = server(MockResponse().setResponseCode(200).setBody("""{"results":[]}"""))
        val origin = server(MockResponse().setResponseCode(302).setHeader("Location", other.url("/v1/tools/search").toString()))
        val (spec, request) = deepseekRequest(origin, "sk-secret")

        val outcome = executor.execute(request, spec, count = null, timeoutSec = 20, custom = false, otherServices = 0)

        assertEquals(1, origin.requestCount)
        assertEquals(0, other.requestCount)
        assertEquals("request_rejected", (outcome as SearchExecution.Failed).outcome.errorClass)
    }

    @Test
    fun `lan http same origin redirect is followed with the key and POST on 302 becomes GET`() = runBlocking {
        val normal = goldenCase("deepseek.normal")
        val s = server(
            MockResponse().setResponseCode(302).setHeader("Location", "/v2/tools/search"),
            MockResponse().setResponseCode(200).setBody(normal.getValue("body").toString()),
        )
        val (spec, request) = deepseekRequest(s, "sk-secret")

        val outcome = executor.execute(request, spec, count = null, timeoutSec = 20, custom = true, otherServices = 0)

        assertEquals(2, s.requestCount)
        s.takeRequest()
        val followed = s.takeRequest()
        assertEquals("/v2/tools/search", followed.path)
        assertEquals("Bearer sk-secret", followed.getHeader("Authorization"))
        assertEquals("GET", followed.method)
        assertEquals(0L, followed.bodySize)
        assertEquals(true, outcome is SearchExecution.Results)
    }

    @Test
    fun `https to http redirect on the same host and port is cross origin and aborted`() = runBlocking {
        val (tls, trust) = selfSignedTls()
        val s = MockWebServer().also { servers += it }
        s.useHttps(tls.socketFactory, false)
        s.start(loopback, 0)
        s.enqueue(MockResponse().setResponseCode(301).setHeader("Location", "http://127.0.0.1:${s.port}/v1/tools/search"))
        val tlsExecutor = SearchExecutor(OkHttpClient.Builder().sslSocketFactory(tls.socketFactory, trust).build(), { listOf("127.0.0.1") })
        val (spec, request) = deepseekRequest(s, "sk-secret", scheme = "https")

        val outcome = tlsExecutor.execute(request, spec, count = null, timeoutSec = 20, custom = true, otherServices = 0)

        assertEquals(1, s.requestCount)
        val failed = (outcome as SearchExecution.Failed).outcome
        assertEquals("request_rejected", failed.errorClass)
        assertEquals("check_settings", failed.card.primaryAction)
    }

    @Test
    fun `more than five same origin redirects are aborted`() = runBlocking {
        val (tls, trust) = selfSignedTls()
        val s = MockWebServer().also { servers += it }
        s.useHttps(tls.socketFactory, false)
        repeat(SearchExecutor.MAX_REDIRECTS + 1) { i ->
            s.enqueue(MockResponse().setResponseCode(302).setHeader("Location", "/hop/$i"))
        }
        s.enqueue(MockResponse().setResponseCode(200).setBody("""{"results":[]}"""))
        s.start(loopback, 0)
        val tlsExecutor = SearchExecutor(OkHttpClient.Builder().sslSocketFactory(tls.socketFactory, trust).build(), { listOf("127.0.0.1") })
        val (spec, request) = deepseekRequest(s, "k", scheme = "https")

        val outcome = tlsExecutor.execute(request, spec, count = null, timeoutSec = 20, custom = false, otherServices = 0)

        assertEquals(SearchExecutor.MAX_REDIRECTS + 1, s.requestCount)
        assertEquals("request_rejected", (outcome as SearchExecution.Failed).outcome.errorClass)
    }

    @Test
    fun `body over two megabytes is aborted as too large`() = runBlocking {
        val huge = "x".repeat(SearchHardLimits.MAX_RESPONSE_BYTES + 1)
        val s = server(MockResponse().setResponseCode(200).setBody(huge))
        val (spec, request) = deepseekRequest(s, "k")

        val outcome = executor.execute(request, spec, count = null, timeoutSec = 20, custom = false, otherServices = 0)

        assertEquals("response_too_large", (outcome as SearchExecution.Failed).outcome.errorClass)
    }

    @Test
    fun `cleartext to a public address is refused before sending`() = runBlocking {
        val s = server(MockResponse().setResponseCode(200).setBody("""{"results":[]}"""))
        val publicResolver = SearchExecutor(OkHttpClient(), { listOf("8.8.8.8") })
        val (spec, request) = deepseekRequest(s, "k")

        val outcome = publicResolver.execute(request, spec, count = null, timeoutSec = 20, custom = true, otherServices = 0)

        assertEquals(0, s.requestCount)
        val failed = (outcome as SearchExecution.Failed).outcome
        assertEquals("request_rejected", failed.errorClass)
        assertEquals("check_settings", failed.card.primaryAction)
    }

    @Test
    fun `preset host check failure sends nothing`() = runBlocking {
        val refusing = OkHttpClient.Builder().addInterceptor { error("request must not be sent") }.build()
        val guarded = SearchExecutor(refusing, { error("must not resolve") })
        val entry = catalogEntry(catalog, "deepseek")

        val changed = guarded.executePreset(entry, "cn", "old.deepseek.com", withdrawn = false, key = "k", query = "q", count = 5)
        val withdrawn = guarded.executePreset(entry, "cn", "api.deepseek.com", withdrawn = true, key = "k", query = "q", count = 5)

        assertEquals("host_changed", (changed as SearchExecution.Failed).outcome.errorClass)
        assertEquals("service_withdrawn", (withdrawn as SearchExecution.Failed).outcome.errorClass)

        // Empty query is not sent; treated as no results
        val blank = guarded.executeCustom("searxng", "https://search.example.com", null, key = null, query = "  \n ", count = 5)
        assertEquals(SearchExecution.Empty, blank)
    }
}
