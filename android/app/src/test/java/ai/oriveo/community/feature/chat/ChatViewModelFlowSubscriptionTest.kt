package ai.oriveo.community.feature.chat

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards against a whole class of cold-flow bugs: `stateIn(..., WhileSubscribed(...), initial)`
 * never starts its upstream when there is **no downstream collector**, so `.value` stays at the
 * initial value forever -- iOS's `@Published` has no such semantics, this is an Android-only trap.
 *
 * Past incidents:
 * - A provider list StateFlow with nobody collecting it made the candidate list always empty,
 *   so the button was permanently dead.
 * - `hasMoreBelow` / `isLoadingBelow` were read directly via `.value` by an effect but were never
 *   collected anywhere in the codebase, so they stayed false forever and the load-more-below path
 *   became dead code -- after jumping to an anchor from a note, scrolling further down did nothing.
 *   The twin `hasMoreAbove` happened to stay alive at the time only because the screen content
 *   needed it for rendering and so collected it -- a coincidence; the moment nothing consumes
 *   that value it silently breaks the same way.
 *
 * Invariant: **a flow received as a `StateFlow` parameter inside ChatScreenEffects must actually
 * call `collectAsStateWithLifecycle()`** inside that composable, and must never be read directly
 * via `.value` -- passing a StateFlow reference down as a parameter does not by itself constitute
 * a subscription.
 *
 * Why "subscribe inside the effect" instead of "switch the ViewModel side to Eagerly": Eagerly
 * would keep the coroutine alive for the lifetime of the ViewModel's viewModelScope (i.e. the
 * main dispatcher) with no cancellation tied to the UI lifecycle; in practice that noticeably
 * amplifies test flakiness (the ChatViewModel test family never cancels viewModelScope, so a
 * single `resetMain` in `@After` orphans these coroutines, which then land on unrelated tests).
 * Subscribing inside an effect-only composable has no recomposition overhead and is automatically
 * canceled with the lifecycle.
 */
class ChatViewModelFlowSubscriptionTest {

    private val effectsSource =
        File("src/main/java/ai/oriveo/community/feature/chat/ChatScreenEffects.kt").readText()

    /** Parameters received in ChatScreenEffects in the form `name: StateFlow<...>`. */
    private val effectFlowNames: List<String> =
        Regex("""(\w+): StateFlow<""")
            .findAll(effectsSource)
            .map { it.groupValues[1] }
            .distinct()
            .toList()

    @Test
    fun `state flow parameters of effects are actually collected`() {
        assertTrue(
            "Could not parse any StateFlow parameters out of ChatScreenEffects.kt; this guard is broken (did the regex or the signature style change?)",
            effectFlowNames.isNotEmpty(),
        )

        val notCollected = effectFlowNames.filterNot { name ->
            effectsSource.contains("$name.collectAsStateWithLifecycle()")
        }

        assertTrue(
            "These StateFlow parameters are never actually collected: $notCollected -- passing the reference down does not constitute a subscription; " +
                "with WhileSubscribed and no subscriber the upstream never starts and .value stays at its initial value forever, so the corresponding branch becomes silently unreachable. " +
                "Call collectAsStateWithLifecycle() inside that effect composable.",
            notCollected.isEmpty(),
        )
    }

    @Test
    fun `effects never read state flow value directly`() {
        val directValueReads = effectFlowNames.filter { name ->
            effectsSource.contains("$name.value")
        }

        assertTrue(
            "These StateFlow parameters are read directly via .value: $directValueReads -- reading directly does not establish a subscription, " +
                "so the value stays at its initial value forever. Switch to collectAsStateWithLifecycle() and read the resulting State instead.",
            directValueReads.isEmpty(),
        )
    }
}
