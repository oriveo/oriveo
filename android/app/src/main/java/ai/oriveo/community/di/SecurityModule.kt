package ai.oriveo.community.di

import kotlinx.coroutines.flow.first
import ai.oriveo.community.core.attachments.extractors.MlKitPdfOcrEngine
import ai.oriveo.community.core.attachments.extractors.PdfOcr
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.mcp.McpCredentialStore
import ai.oriveo.community.core.security.SecureKeyStore
import ai.oriveo.community.feature.chat.attachments.AttachmentProcessor
import org.koin.android.ext.koin.androidContext
import org.koin.dsl.module

val securityModule = module {
    single { SecureKeyStore(androidContext()) }
    // MCP credentials share the one SecureKeyStore singleton with the API keys; they only live in
    // an encrypted prefs file of their own.
    single { McpCredentialStore(get<SecureKeyStore>()) }
    // External search service list and keys: separate encrypted prefs, partitioned by account; the Keystore is not opened at construction.
    single { ai.oriveo.community.core.search.SearchServiceStore(androidContext()) }
    // External search catalog (cache -> built-in snapshot -> network) and request executor: shared by the settings test search and chat.
    single { ai.oriveo.community.core.search.SearchCatalogRepository(androidContext()) }
    single { ai.oriveo.community.core.search.SearchExecutor() }
    single<ai.oriveo.community.feature.chat.modelcontrols.ModelControlsWebSearch> {
        val providers = get<ai.oriveo.community.core.data.repository.ProviderRepository>()
        ai.oriveo.community.feature.chat.modelcontrols.StoreModelControlsWebSearch(
            store = get(),
            catalog = get(),
            connections = {
                ai.oriveo.community.feature.settings.websearch.webSearchConnections(providers.observeAll().first())
            },
            // Catalog evidence tri-state (first-party / catalog > rejection memory > modelFacts > declared > remembered true > unknown)
            toolCallVerdict = { p, m ->
                ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter.toolCallVerdict(
                    p, m, memoryVerdict = providers.toolCallMemoryVerdict(p, m),
                )
            },
            executor = get(),
            // The key of a reused connection is fetched only just before sending a request (same resolution entry as the settings test)
            connectionKey = { id ->
                providers.observeAll().first().firstOrNull { it.id == id }
                    ?.let { ai.oriveo.community.core.provider.ProviderCredentialResolver.apiKey(it, null) }
            },
        )
    }
    single { AttachmentStore(androidContext()) }
    // ML Kit OCR for scanned PDFs (spec section 13); needs a Context to render pages and build the recognizer.
    single { PdfOcr(MlKitPdfOcrEngine(androidContext())) }
    single { AttachmentProcessor(attachmentStore = get(), pdfOcr = get()) }
}
