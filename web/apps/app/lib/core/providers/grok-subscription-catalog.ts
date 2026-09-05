/**
 * Catalog construction for the subscription path.
 *
 * The official catalog describes the pay-as-you-go path on `api.x.ai` (grok-4.3 / grok-code-fast-1 and
 * so on), while a subscription goes through the CLI proxy, which is a different path: as of 2026-08 it
 * only accepts `grok-4.6` / `grok-4.5`. Without building this catalog separately, every model the user
 * can pick in the list is absent on that path and the first message fails.
 */

import type { AIModel } from '@oriveo/shared';
import type { GrokModelDescriptor } from '@oriveo/core/providers/grok-subscription';

/**
 * Builds the subscription catalog into usable models.
 *
 * Prices and capabilities are not read from the official catalog: this path is not billed per token
 * (the user pays a monthly fee), and forcing a priceTier in would show a unit price that does not exist.
 *
 * **Capabilities are copied from what the upstream declares.** Subscription models are absent from the
 * official catalog, and hardcoding `['text']` with no reasoning made the UI offer web search and thinking
 * while the outbound request always said false. Nothing declared means degrade; anything declared takes
 * effect on its own, so a new model needs no client change.
 *
 * A plain id list is still accepted: older callers and upstreams that only return ids degrade to no capabilities.
 */
export function buildGrokSubscriptionModels(
  models: Array<string | GrokModelDescriptor>,
  summary?: string,
): AIModel[] {
  const descriptors: GrokModelDescriptor[] = models.map((entry) =>
    typeof entry === 'string'
      ? {
          id: entry,
          supportsWebSearch: false,
          supportsReasoning: false,
          reasoningEfforts: [],
        }
      : entry,
  );
  const preferred = descriptors[0]?.id;
  return descriptors.map((descriptor) => {
    const capabilities: AIModel['capabilities'] = ['text'];
    if (descriptor.supportsWebSearch) capabilities.push('web');
    if (descriptor.supportsReasoning) capabilities.push('reasoning');
    return {
      id: descriptor.id,
      name: descriptor.displayName || descriptor.id,
      capabilities,
      reasoningModeAvailable: descriptor.supportsReasoning,
      isAvailable: true,
      isDefault: descriptor.id === preferred,
      priceTier: '',
      // Carry the upstream-declared level table through: outbound uses it to validate that only values
      // the upstream accepts are sent. Discarding it after parsing made "levels come from the declared
      // set" untrue here. Persisted locally but **not** synced to the cloud (excluded from the
      // sync envelope allowlist mapping).
      ...(descriptor.reasoningEfforts.length > 0
        ? { upstreamReasoningLevels: descriptor.reasoningEfforts }
        : {}),
      ...(descriptor.defaultReasoningEffort
        ? { upstreamDefaultReasoningLevel: descriptor.defaultReasoningEffort }
        : {}),
      ...(descriptor.apiBackend ? { upstreamApiBackend: descriptor.apiBackend } : {}),
      ...(descriptor.contextWindow ? { contextLength: descriptor.contextWindow } : {}),
      ...(summary ? { summary } : {}),
    };
  });
}
