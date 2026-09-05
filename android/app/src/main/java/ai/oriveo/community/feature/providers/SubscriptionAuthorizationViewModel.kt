package ai.oriveo.community.feature.providers

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.core.provider.grok.GrokSubscriptionOAuthClient
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionOAuthClient
import ai.oriveo.community.feature.providers.grok.GrokSubscriptionAuthorizationModel
import ai.oriveo.community.feature.providers.openai.OpenAISubscriptionAuthorizationModel
import io.ktor.client.HttpClient

/**
 *
 *
 *
 *
 */
class SubscriptionAuthorizationViewModel(
    httpClient: HttpClient,
    private val savedState: SavedStateHandle,
) : ViewModel() {

    val openAI: OpenAISubscriptionAuthorizationModel = OpenAISubscriptionAuthorizationModel(
        client = OpenAISubscriptionOAuthClient(httpClient),
        scope = viewModelScope,
        snapshotStore = snapshotStore(KEY_OPENAI),
    )

    val grok: GrokSubscriptionAuthorizationModel = GrokSubscriptionAuthorizationModel(
        client = GrokSubscriptionOAuthClient(httpClient),
        scope = viewModelScope,
        snapshotStore = snapshotStore(KEY_GROK),
    )

    /**
     *
     */
    private fun snapshotStore(key: String) = object : SubscriptionAuthorizationSnapshotStore {
        override fun read(): String? = savedState[key]

        override fun write(value: String?) {
            if (value == null) savedState.remove<String>(key) else savedState[key] = value
        }
    }

    private companion object {
        const val KEY_OPENAI = "subscription_authorization_openai"
        const val KEY_GROK = "subscription_authorization_grok"
    }
}
