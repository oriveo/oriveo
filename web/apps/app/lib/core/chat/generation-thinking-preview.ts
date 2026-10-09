/**
 * Thinking-linkage preview for advanced settings: it only answers "will this outbound request turn thinking on, and with what budget", using the same function as outbound.
 * The dropped-items list itself is computed by the row model through `guardAnthropicThinking`, not here.
 */
import { resolveRelayAnthropicThinking } from '@oriveo/core/providers/request-builders/anthropic-thinking';
import { buildProviderRequest, type MetadataProvider } from '@oriveo/core/providers/request-builders/dispatch';
import type { CapabilityPreferenceInput, GenerationParameterProfile } from '@oriveo/core/providers/request-builders/types';
import type { AIModel, Provider, ReasoningMode } from '@oriveo/shared';
import { browserOfficialMetadata } from '../metadata/metadata-client';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent, filterRequestCapabilityIntent, providerControlsAreManaged } from './stream-options';

export interface ThinkingPreviewInput {
  provider: Provider;
  model: AIModel;
  profile: GenerationParameterProfile | undefined;
  reasoningMode: ReasoningMode;
  /** Preferences obtained through the same read chain as the send path (`resolveCapabilityPreferences`). */
  capabilityPreferences?: CapabilityPreferenceInput;
  /**
   * The metadata the builder uses when an official connection sends. Defaults to the browser-side /api/metadata payload
   * (`browserOfficialMetadata`); when it is not loaded yet the preview returns null -- no guessing.
   */
  officialMetadata?: MetadataProvider;
}

export async function activeThinkingForPreview(input: ThinkingPreviewInput): Promise<{ budgetTokens?: number } | null> {
  const { provider, model } = input;
  if (input.profile?.template !== 'anthropic_messages') return null;
  if (providerControlsAreManaged(provider)) return null;
  const reasoning = requestReasoning(input);
  if (provider.kind === 'relay') {
    const thinking = resolveRelayAnthropicThinking(reasoning.reasoning);
    return thinking ? { budgetTokens: thinking.budgetTokens } : null;
  }
  if (provider.kind !== 'anthropic') return null;
  const metadata = await (input.officialMetadata ?? (() => browserOfficialMetadata('anthropic')))();
  if (!metadata) return null;
  // Official thinking fields are written by the metadata capability recipe / reasoning profile, so the same builder is simply run once.
  const request = await buildProviderRequest({
    providerKind: 'anthropic', apiKey: '', modelID: model.id,
    messages: [{ role: 'user', content: '' }],
    options: {
      ...(reasoning.reasoning !== undefined ? { reasoning: reasoning.reasoning } : {}),
      ...(reasoning.capabilityPreferences ? { capabilityPreferences: reasoning.capabilityPreferences } : {}),
    },
  }, async () => metadata);
  const thinking = request.body.thinking as { type?: unknown; budget_tokens?: unknown } | undefined;
  if (!thinking || (thinking.type !== 'enabled' && thinking.type !== 'adaptive')) return null;
  return typeof thinking.budget_tokens === 'number' ? { budgetTokens: thinking.budget_tokens } : {};
}

/** Same ladder as `operations-send`: intent -> connection options -> tiers left after the outbound gate filters them. */
function requestReasoning(input: ThinkingPreviewInput) {
  const { provider, model, reasoningMode } = input;
  const preliminary = buildProviderStreamOptions(
    provider,
    buildStreamOptionsFromIntent(model, reasoningMode, false, undefined, input.capabilityPreferences),
    model,
  );
  return filterRequestCapabilityIntent({ provider, model, reasoningMode, webSearchEnabled: false, streamOptions: preliminary });
}
