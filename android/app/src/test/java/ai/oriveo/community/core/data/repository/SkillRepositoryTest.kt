package ai.oriveo.community.core.data.repository

import android.util.Log
import ai.oriveo.community.core.auth.AccountSessionManager
import ai.oriveo.community.core.auth.AuthenticationController
import ai.oriveo.community.core.data.api.SkillApiService
import ai.oriveo.community.core.data.dao.SkillDao
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class SkillRepositoryTest {

    @Before
    fun setUp() {
        mockkStatic(Log::class)
        every { Log.d(any(), any(), any()) } returns 0
    }

    @After
    fun tearDown() {
        unmockkStatic(Log::class)
    }

    @Test
    fun refresh_catalog_failure_is_caught_by_refresh_all() = runTest {
        val api = mockk<SkillApiService>()
        val dao = mockk<SkillDao>(relaxed = true)
        val authController = mockk<AuthenticationController>()
        val accountSession = mockk<AccountSessionManager>()
        every { accountSession.currentAccountId } returns MutableStateFlow("account-1")
        coEvery { dao.countBySource("account-1", "builtin") } returns 3
        coEvery { api.fetchCatalog(any()) } throws IllegalStateException("catalog down")
        coEvery { authController.currentIdToken(forceRefresh = false) } returns null
        val repository = SkillRepository(
            api = api,
            dao = dao,
            authController = authController,
            accountSession = accountSession,
            catalogStore = mockk(relaxed = true),
        )

        // refreshCatalog alone propagates, so the templates segment can show its failed row.
        val direct = runCatching { repository.refreshCatalog() }
        assertEquals("catalog down", direct.exceptionOrNull()?.message)

        // refreshAll swallows it and still refreshes the user's own skills.
        val all = runCatching { repository.refreshAll() }
        assertTrue("refreshAll must not rethrow a catalog failure", all.isSuccess)
        coVerify(exactly = 2) { api.fetchCatalog(any()) }
        coVerify(exactly = 1) { authController.currentIdToken(forceRefresh = false) }
        coVerify(exactly = 0) { dao.replaceBySource(any(), "builtin", any()) }
    }
}
