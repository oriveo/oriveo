package ai.oriveo.community.core.provider

import ai.oriveo.community.core.attachments.AttachmentDelivery
import ai.oriveo.community.core.attachments.AttachmentHydrator
import ai.oriveo.community.core.attachments.AttachmentInjector
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ReasoningMode

/**
 * Whether this turn's attachments fit when send is tapped in the composer.
 *
 * It uses the same [AttachmentDelivery.plan] and the same route resolution ([AttachmentTransportResolver]) as the real send.
 * When the entry point can supply this turn's actual options, the verdict is for that route; when it cannot, an error is returned only if the attachments do not fit on any possible route.
 * Anything that cannot be decided right now returns null and is left to the failure card at send time.
 */
object AttachmentSendPreflight {

    /**
     * The options this send will actually use outbound, taken by the send entry point from the same resolution as the outbound path.
     *
     * @property toolLoopPossible The tool loop (MCP) may take over this send: leg requests always build messages as Chat Completions,
     *   and whether it takes over is only decided after sending, so when true the leg route counts as a possibility too.
     */
    data class SendOptions(
        val reasoningMode: ReasoningMode,
        val webSearchEnabled: Boolean,
        val toolLoopPossible: Boolean,
    )

    fun undeliverable(
        provider: Provider,
        model: AIModel,
        text: String,
        attachments: List<Attachment>?,
        options: SendOptions? = null,
    ): ProviderServiceError? {
        val all = attachments.orEmpty()
        if (all.none { it.kind == AttachmentKind.File }) return null
        // A file whose content is still on disk: its body size is only known once it is hydrated at send time.
        val settled = all.map { AttachmentHydrator.assumeHydratedForRouting(it) ?: return null }
        val routes = if (options == null) {
            AttachmentTransportResolver.possibleRoutes(provider, model)
        } else {
            AttachmentTransportResolver.routesFor(
                provider, model, options.webSearchEnabled, options.reasoningMode, options.toolLoopPossible,
            )
        } ?: return null
        val errors = routes.map { route ->
            AttachmentDelivery.undeliverable(
                AttachmentDelivery.plan(
                    baseText = text.trim(),
                    attachments = settled,
                    model = route.model,
                    transport = route.transport,
                ),
            ) ?: return null
        }
        return errors.firstOrNull()
    }

    /**
     * At add time: whether, once [incoming] is put in the composer, it does not fit the text total on any possible route.
     * Anything that cannot be decided (the route does not resolve, content is still on disk) is false and left to the send-time check.
     *
     * It uses the same [AttachmentDelivery.plan] as sending, so rules such as limit resolution and native files not using the text budget
     * are not written a second time here. The count limit is not this gate's concern: that is a different gate at add time with its own sentence.
     */
    fun exceedsTextBudgetOnAdd(
        provider: Provider,
        model: AIModel,
        existing: List<Attachment>,
        incoming: Attachment,
    ): Boolean {
        if (incoming.kind != AttachmentKind.File) return false
        val settled = (existing + incoming).map { AttachmentHydrator.assumeHydratedForRouting(it) ?: return false }
        val routes = AttachmentTransportResolver.possibleRoutes(provider, model) ?: return false
        return routes.isNotEmpty() && routes.all { route ->
            val plan = AttachmentDelivery.plan(
                baseText = "",
                attachments = settled,
                model = route.model,
                transport = route.transport,
            )
            // File entries correspond one to one with File attachments, in the same order; the newly added one is last.
            plan.items.lastOrNull()?.skipReason == AttachmentInjector.SkipReason.TotalCapExceeded
        }
    }
}
