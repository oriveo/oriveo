package ai.oriveo.community.core.model

import ai.oriveo.community.core.model.ProviderKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class BackupModelsTest {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    // ── ImportMode ──────────────────────────────────────────────

    @Test
    fun `ImportMode entries contains all three modes`() {
        val entries = ImportMode.entries
        assertEquals(3, entries.size)
        assertTrue(entries.contains(ImportMode.ImportNewOnly))
        assertTrue(entries.contains(ImportMode.Merge))
        assertTrue(entries.contains(ImportMode.ReplaceAll))
    }

    @Test
    fun `ImportMode isDefault only for ImportNewOnly`() {
        assertTrue(ImportMode.ImportNewOnly.isDefault)
        assertFalse(ImportMode.Merge.isDefault)
        assertFalse(ImportMode.ReplaceAll.isDefault)
    }

    @Test
    fun `ImportMode all have valid resource IDs`() {
        ImportMode.entries.forEach { mode ->
            assertTrue("titleResId should be positive for $mode", mode.titleResId > 0)
            assertTrue("descriptionResId should be positive for $mode", mode.descriptionResId > 0)
        }
    }

    // ── ImportPreview ──────────────────────────────────────────

    @Test
    fun `ImportPreview stores all fields correctly`() {
        val preview = ImportPreview(
            backupCreatedAt = "2026-03-19 10:00",
            backupPlatform = "iOS",
            backupAppVersion = "1.0",
            containsKeys = true,
            totalConversations = 42,
            existingConversations = 10,
            totalProviders = 5,
            existingProviders = 1,
            totalMessages = 234,
            totalImages = 12,
        )

        assertEquals("2026-03-19 10:00", preview.backupCreatedAt)
        assertEquals("iOS", preview.backupPlatform)
        assertEquals("1.0", preview.backupAppVersion)
        assertTrue(preview.containsKeys)
        assertEquals(42, preview.totalConversations)
        assertEquals(10, preview.existingConversations)
        assertEquals(5, preview.totalProviders)
        assertEquals(1, preview.existingProviders)
        assertEquals(234, preview.totalMessages)
        assertEquals(12, preview.totalImages)
    }

    @Test
    fun `ImportPreview defaults false for containsKeys`() {
        val preview = ImportPreview(
            backupCreatedAt = "",
            backupPlatform = "Android",
            backupAppVersion = "1.0",
            containsKeys = false,
            totalConversations = 0,
            existingConversations = 0,
            totalProviders = 0,
            existingProviders = 0,
            totalMessages = 0,
            totalImages = 0,
        )
        assertFalse(preview.containsKeys)
    }

    // ── ImportResult ──────────────────────────────────────────

    @Test
    fun `ImportResult defaults to all zeros`() {
        val result = ImportResult()
        assertEquals(0, result.newConversations)
        assertEquals(0, result.skippedConversations)
        assertEquals(0, result.mergedConversations)
        assertEquals(0, result.newProviders)
        assertEquals(0, result.skippedProviders)
        assertEquals(0, result.newNotes)
        assertEquals(0, result.mergedNotes)
        assertEquals(0, result.skippedNotes)
        assertEquals(0, result.newNoteFolders)
        assertEquals(0, result.mergedNoteFolders)
        assertEquals(0, result.skippedNoteFolders)
        assertEquals(0, result.restoredKeys)
        assertEquals(0, result.restoredImages)
        assertEquals(0, result.skippedImages)
    }

    @Test
    fun `ImportResult hasChanges returns true when new conversations exist`() {
        val result = ImportResult(newConversations = 1)
        assertTrue(result.hasChanges)
    }

    @Test
    fun `ImportResult hasChanges returns true when merged conversations exist`() {
        val result = ImportResult(mergedConversations = 5)
        assertTrue(result.hasChanges)
    }

    @Test
    fun `ImportResult hasChanges returns true when new providers exist`() {
        val result = ImportResult(newProviders = 2)
        assertTrue(result.hasChanges)
    }

    @Test
    fun `ImportResult hasChanges returns true when restored keys exist`() {
        val result = ImportResult(restoredKeys = 3)
        assertTrue(result.hasChanges)
    }

    @Test
    fun `ImportResult hasChanges returns true when notes are imported`() {
        assertTrue(ImportResult(newNotes = 2).hasChanges)
        assertTrue(ImportResult(mergedNotes = 1).hasChanges)
        assertTrue(ImportResult(newNoteFolders = 1).hasChanges)
        assertTrue(ImportResult(mergedNoteFolders = 1).hasChanges)
    }

    @Test
    fun `ImportResult hasChanges returns false when only skipped items`() {
        val result = ImportResult(
            skippedConversations = 10,
            skippedProviders = 3,
            skippedNotes = 4,
            skippedNoteFolders = 2,
            skippedImages = 5,
        )
        assertFalse(result.hasChanges)
    }

    @Test
    fun `ImportResult hasChanges returns false when only images restored`() {
        val result = ImportResult(restoredImages = 10)
        assertFalse(result.hasChanges)
    }

    @Test
    fun `ImportResult hasChanges returns false for empty result`() {
        assertFalse(ImportResult().hasChanges)
    }

    // ── BackupFile ──────────────────────────────────────────

    @Test
    fun `BackupFile stores all required fields`() {
        val file = BackupFile(
            version = 1,
            createdAt = "2026-03-19T10:00:00Z",
            appVersion = "1.0 (1)",
            platform = "Android",
            checksum = "sha256:abc123",
            containsKeys = false,
            data = BackupData(),
        )

        assertEquals(1, file.version)
        assertEquals("Android", file.platform)
        assertEquals("sha256:abc123", file.checksum)
        assertFalse(file.containsKeys)
        assertTrue(file.data.providers.isEmpty())
        assertTrue(file.data.conversations.isEmpty())
    }

    @Test
    fun `BackupFile optional fields default to null`() {
        val file = BackupFile(
            version = 1,
            createdAt = "",
            appVersion = "",
            platform = "",
            checksum = "",
            containsKeys = false,
            data = BackupData(),
        )

        assertFalse(file.containsKeys)
        assertEquals(null, file.attachmentChecksums)
        assertEquals(null, file.encryptedKeys)
    }

    // ── BackupData ──────────────────────────────────────────

    @Test
    fun `BackupData defaults to empty lists`() {
        val data = BackupData()
        assertTrue(data.providers.isEmpty())
        assertTrue(data.folders.isEmpty())
        assertTrue(data.conversations.isEmpty())
        assertEquals(null, data.preferences)
        assertEquals(null, data.lastUsedModelRef)
    }

    @Test
    fun `BackupData decode is backward compatible when folders field is missing`() {
        val decoded = json.decodeFromString<BackupData>(
            """
            {
              "providers": [],
              "conversations": []
            }
            """.trimIndent(),
        )

        assertTrue(decoded.folders.isEmpty())
        assertTrue(decoded.providers.isEmpty())
        assertTrue(decoded.conversations.isEmpty())
    }

    // ── BackupProvider ──────────────────────────────────────

    @Test
    fun `BackupProvider stores provider info without sensitive data`() {
        val bp = BackupProvider(
            id = "test-id",
            kind = ProviderKind.OpenAI,
            baseURLText = "api.openai.com/v1",
            customName = null,
            models = listOf(
                AIModel(id = "gpt-4", name = "GPT-4"),
            ),
        )

        assertEquals("test-id", bp.id)
        assertEquals(ProviderKind.OpenAI, bp.kind)
        assertEquals("api.openai.com/v1", bp.baseURLText)
        assertEquals(1, bp.models.size)
    }

    // ── BackupConversation ──────────────────────────────────

    @Test
    fun `BackupConversation stores conversation data without drafts`() {
        val bc = BackupConversation(
            id = "conv-1",
            title = "Test Conversation",
            providerID = "prov-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "gpt-4",
            previewText = "Hello world",
            estimatedCost = 0.002,
            messages = emptyList(),
        )

        assertEquals("conv-1", bc.id)
        assertEquals("Test Conversation", bc.title)
        assertEquals("prov-1", bc.providerID)
        assertEquals("gpt-4", bc.modelID)
        assertEquals("Hello world", bc.previewText)
        assertEquals(0.002, bc.estimatedCost, 0.0001)
    }

    @Test
    fun `BackupConversation keeps folderID in serialization roundtrip`() {
        val original = BackupConversation(
            id = "conv-folder",
            title = "Folder Conversation",
            providerID = "prov-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "gpt-4",
            folderID = "folder-123",
            updatedAt = 12345L,
        )

        val encoded = json.encodeToString(original)
        val decoded = json.decodeFromString<BackupConversation>(encoded)

        assertEquals("folder-123", decoded.folderID)
    }

    // ── BackupFolder ──────────────────────────────────────────

    @Test
    fun `BackupFolder serialization roundtrip keeps all fields`() {
        val original = BackupFolder(
            id = "folder-1",
            name = "Work",
            sortOrder = 2000,
            createdAt = 1700000000000L,
            updatedAt = 1700000001234L,
        )

        val encoded = json.encodeToString(original)
        val decoded = json.decodeFromString<BackupFolder>(encoded)

        assertEquals(original, decoded)
    }

    // ── LastUsedModelRef ──────────────────────────────────────

    @Test
    fun `LastUsedModelRef stores provider and model ID`() {
        val ref = LastUsedModelRef(
            providerID = "prov-1",
            modelID = "claude-4-sonnet",
        )

        assertEquals("prov-1", ref.providerID)
        assertEquals("claude-4-sonnet", ref.modelID)
    }

    // ── BackupPreferences ──────────────────────────────────

    @Test
    fun `BackupPreferences defaults to system`() {
        val prefs = BackupPreferences()
        assertEquals("system", prefs.theme)
        assertEquals("system", prefs.language)
    }

    @Test
    fun `BackupPreferences stores custom values`() {
        val prefs = BackupPreferences(theme = "dark", language = "ja")
        assertEquals("dark", prefs.theme)
        assertEquals("ja", prefs.language)
    }

    // ── BackupKeyEntry ──────────────────────────────────────

    @Test
    fun `BackupKeyEntry stores key data`() {
        val entry = BackupKeyEntry(
            providerID = "prov-1",
            apiKey = "sk-test123",
            apiKeyPreview = "sk-...123",
        )

        assertEquals("prov-1", entry.providerID)
        assertEquals("sk-test123", entry.apiKey)
        assertEquals("sk-...123", entry.apiKeyPreview)
    }
}
