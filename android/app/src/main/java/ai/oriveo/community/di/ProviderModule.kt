package ai.oriveo.community.di

import ai.oriveo.community.core.provider.AnthropicService
import ai.oriveo.community.core.provider.BalanceQueryable
import ai.oriveo.community.core.provider.DeepSeekService
import ai.oriveo.community.core.provider.FireworksService
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.provider.GeminiService
import ai.oriveo.community.core.provider.GrokService
import ai.oriveo.community.core.provider.GroqService
import ai.oriveo.community.core.provider.MiniMaxService
import ai.oriveo.community.core.provider.MistralService
import ai.oriveo.community.core.provider.MoonshotService
import ai.oriveo.community.core.provider.ZhipuService
import ai.oriveo.community.core.provider.QwenService
import ai.oriveo.community.core.provider.SiliconFlowService
import ai.oriveo.community.core.provider.OpenAIService
import ai.oriveo.community.core.provider.OpenRouterService
import ai.oriveo.community.core.provider.ProviderBalanceRepository
import ai.oriveo.community.core.provider.TogetherService
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.RelayDiscoveryService
import ai.oriveo.community.core.model.ProviderKind
import org.koin.core.qualifier.named
import org.koin.dsl.bind
import org.koin.dsl.module

val providerModule = module {
    
    single { TransportRegistry(get()) }

    
    
    single {
        OpenRouterService(get(), get(), get())
    } bind BalanceQueryable::class
    single { OpenAIService(get(), get(), get()) }
    single { RelayService(get(), get(), get()) }
    single { RelayDiscoveryService(get(), get()) }
    single { ai.oriveo.community.core.provider.LocalEngineConnector(get(), get(), get()) }
    single { ai.oriveo.community.core.provider.LocalEngineRuntimeClient(get(), get()) }
    single {
        DeepSeekService(get(), get())
    } bind BalanceQueryable::class
    single { GrokService(get(), get(), get()) }
    single { AnthropicService(get(), get(), get()) }
    single { GeminiService(get(), get(), get()) }
    single { GroqService(get(), get()) }
    single { TogetherService(get(), get()) }
    single { FireworksService(get(), get()) }
    single { MiniMaxService(get(), get()) }
    single { ZhipuService(get(), get(), get()) }
    single { QwenService(get(), get(), get()) }
    single {
        MoonshotService(get(), get(), get())
    } bind BalanceQueryable::class
    single { MistralService(get(), get(), get()) }
    single {
        SiliconFlowService(get(), get())
    } bind BalanceQueryable::class

    
    
    single(named("balance.openRouter")) { get<OpenRouterService>() as BalanceQueryable }
    single(named("balance.deepseek")) { get<DeepSeekService>() as BalanceQueryable }
    single(named("balance.moonshot")) { get<MoonshotService>() as BalanceQueryable }
    single(named("balance.siliconFlow")) { get<SiliconFlowService>() as BalanceQueryable }
    single {
        ProviderBalanceRepository(
            services = mapOf(
                ProviderKind.OpenRouter to get<BalanceQueryable>(named("balance.openRouter")),
                ProviderKind.DeepSeek to get<BalanceQueryable>(named("balance.deepseek")),
                ProviderKind.Moonshot to get<BalanceQueryable>(named("balance.moonshot")),
                ProviderKind.SiliconFlow to get<BalanceQueryable>(named("balance.siliconFlow")),
            ),
        )
    }
}
