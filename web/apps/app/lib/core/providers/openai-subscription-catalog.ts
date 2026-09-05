/**
 * Catalog construction for the Codex subscription route.
 *
 * The official catalog describes the pay-as-you-go route on `api.openai.com` (gpt-4o, o3 and so
 * on), while a subscription talks to the Codex backend, which is a different route: as of
 * 2026-08 it exposes gpt-5.6-sol / terra / luna. Without building this catalog separately, every
 * model a user picks from the list is absent on that route and the first message fails.
 */

import type { AIModel } from '@oriveo/shared';
import {
  codexDescriptorSupportsReasoning,
  type CodexModelDescriptor,
} from '@oriveo/core/providers/openai-subscription';

/**
 * Turn the Codex catalog into usable models.
 *
 * Price and capability are not taken from the official catalog: this route is not billed per
 * token, since the user pays a ChatGPT subscription, and forcing a priceTier in would make the
 * UI show a unit price that does not exist.
 *
 * Capabilities are copied straight from the upstream declaration: `/models` sends
 * `web_search_tool_type`, `supported_reasoning_levels` and `input_modalities` per model. What the
 * upstream does not declare degrades to unsupported, and anything it starts declaring takes
 * effect on its own, so a new model needs no client change. Guessing a capability from the slug
 * would be exactly the model-id inference that is never allowed.
 *
 * `upstreamReasoningLevels` is carried through verbatim and used to validate level admission on
 * the way out. It is stored locally but never synced: without it, the level table is empty after
 * a cold start and the thinking control disappears, while syncing it to other clients is the real
 * risk, because they have no moment at which they refetch the catalog and a renamed upstream
 * level would leave them sending a value the upstream rejects. The exclusion lives in the
 * allowlist mapping used by the sync envelope.
 */
export function buildOpenAISubscriptionModels(
  descriptors: CodexModelDescriptor[],
  summary?: string,
): AIModel[] {
  // The upstream orders by priority, so the first entry is the default.
  const preferred = descriptors[0]?.slug;
  return descriptors.map((descriptor) => {
    const supportsReasoning = codexDescriptorSupportsReasoning(descriptor);
    const capabilities: AIModel['capabilities'] = ['text'];
    if (descriptor.supportsWebSearch) capabilities.push('web');
    if (supportsReasoning) capabilities.push('reasoning');
    if (descriptor.supportsImageInput) capabilities.push('image');
    return {
      id: descriptor.slug,
      name: descriptor.displayName || descriptor.slug,
      capabilities,
      reasoningModeAvailable: supportsReasoning,
      isAvailable: true,
      isDefault: descriptor.slug === preferred,
      priceTier: '',
      ...(descriptor.supportedReasoningLevels.length > 0
        ? { upstreamReasoningLevels: descriptor.supportedReasoningLevels }
        : {}),
      ...(descriptor.contextWindow ? { contextLength: descriptor.contextWindow } : {}),
      ...(summary ? { summary } : {}),
    };
  });
}
