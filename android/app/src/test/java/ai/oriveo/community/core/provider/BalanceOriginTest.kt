package ai.oriveo.community.core.provider

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Regional endpoint derivation: the host used for the balance endpoint has to be taken from the
 * baseURL the user configured, never hard-coded to a vendor domain. Moonshot ships two hosts and
 * users routinely point the transport at their own gateway, so a hard-coded host is wrong for both.
 */
class BalanceOriginTest {

    @Test
    fun `null baseURL falls back to the fallback origin`() {
        assertEquals(
            "https://api.moonshot.ai",
            balanceOriginOf(null, "https://api.moonshot.ai"),
        )
    }

    @Test
    fun `blank baseURL falls back to the fallback origin`() {
        assertEquals(
            "https://api.deepseek.com",
            balanceOriginOf("", "https://api.deepseek.com"),
        )
        assertEquals(
            "https://api.deepseek.com",
            balanceOriginOf("   ", "https://api.deepseek.com"),
        )
    }

    @Test
    fun `Moonshot dot cn baseURL yields the cn host`() {
        // With https://api.moonshot.cn/v1 configured as the transport, the balance endpoint has to
        // stay on the .cn host as well.
        assertEquals(
            "https://api.moonshot.cn",
            balanceOriginOf("https://api.moonshot.cn/v1", "https://api.moonshot.ai"),
        )
    }

    @Test
    fun `Moonshot dot ai baseURL yields the ai host`() {
        assertEquals(
            "https://api.moonshot.ai",
            balanceOriginOf("https://api.moonshot.ai/v1", "https://api.moonshot.ai"),
        )
    }

    @Test
    fun `DeepSeek baseURL containing v1 keeps only the origin so the path is not doubled`() {
        // Chat goes to ${origin}/v1/chat/completions but the balance endpoint hangs off the root as
        // ${origin}/user/balance, so the join has to produce https://api.deepseek.com/user/balance
        // rather than /v1/user/balance.
        val origin = balanceOriginOf("https://api.deepseek.com/v1", "https://api.deepseek.com")
        assertEquals("https://api.deepseek.com", origin)
        assertEquals("https://api.deepseek.com/user/balance", "$origin/user/balance")
    }

    @Test
    fun `OpenRouter baseURL containing api v1 keeps only the origin`() {
        val origin = balanceOriginOf("https://openrouter.ai/api/v1", "https://openrouter.ai")
        assertEquals("https://openrouter.ai", origin)
        assertEquals("https://openrouter.ai/api/v1/credits", "$origin/api/v1/credits")
    }

    @Test
    fun `SiliconFlow baseURL containing v1 does not repeat v1`() {
        val origin = balanceOriginOf("https://api.siliconflow.cn/v1", "https://api.siliconflow.cn")
        assertEquals("https://api.siliconflow.cn", origin)
        assertEquals("https://api.siliconflow.cn/v1/user/info", "$origin/v1/user/info")
    }

    @Test
    fun `a custom host is extracted just the same`() {
        assertEquals(
            "https://my-proxy.example.com",
            balanceOriginOf("https://my-proxy.example.com/openai/v1", "https://api.moonshot.ai"),
        )
    }

    @Test
    fun `a baseURL with an explicit port keeps the port`() {
        assertEquals(
            "https://localhost:8080",
            balanceOriginOf("https://localhost:8080/v1", "https://api.moonshot.ai"),
        )
    }

    @Test
    fun `a scheme-less host gets https prepended, matching what the chat path does`() {
        // Typing `api.moonshot.cn/v1` without a scheme into the provider baseURL is a common way to
        // configure this. OkHttp fills the scheme in for the chat path, so the balance path has to
        // fill it in too; otherwise a CN key ends up hitting the fallback global host, comes back
        // 401, and the UI reports "API Key invalid" for a key that is perfectly good.
        assertEquals(
            "https://api.moonshot.cn",
            balanceOriginOf("api.moonshot.cn/v1", "https://api.moonshot.ai"),
        )
        assertEquals(
            "https://api.moonshot.cn",
            balanceOriginOf("api.moonshot.cn", "https://api.moonshot.ai"),
        )
    }

    @Test
    fun `a baseURL that cannot be parsed at all falls back`() {
        // Guards against a null origin when the value is badly mistyped: illegal characters, a bare
        // scheme, whitespace only.
        assertEquals(
            "https://api.moonshot.ai",
            balanceOriginOf("http://", "https://api.moonshot.ai"),
        )
    }
}
