/**
 * TransportStrategy registry and factory functions.
 *
 * Each of the 12 kinds maps to one Strategy singleton.
 * An unknown kind reports telemetry.track('unknown_transport_kind') and throws
 * UnsupportedTransportError; callers should use that to hide the model in the picker
 * (forward-compat).
 *
 * Telemetry is injected optionally through TelemetryPort (a no-op when none is provided),
 * so core is not bound to a specific SDK.
 */

import type { AIModel } from '@oriveo/shared/pure-types';
import type { TelemetryPort } from '../../ports';
import {
  TRANSPORT_KIND_SET,
  UnsupportedTransportError,
  isKnownTransportKind,
  type TransportKind,
} from './transport-kind';
import type { TransportStrategy } from './transport-strategy';
import { openAIChatStrategy } from './strategies/openai-chat';
import { openAIResponsesStrategy } from './strategies/openai-responses';
import { anthropicMessagesStrategy } from './strategies/anthropic-messages';
import { geminiGenerateStrategy } from './strategies/gemini-generate';
import { dashscopeNativeStrategy } from './strategies/dashscope-native';
import {
  openAIImagesStrategy,
  geminiImageStrategy,
  qwenImageStrategy,
  grokImageStrategy,
  zhipuImageStrategy,
  anthropicFilesStrategy,
  openAIFilesStrategy,
} from './strategies/image-strategies';

const STRATEGIES: Record<TransportKind, TransportStrategy> = {
  openai_chat: openAIChatStrategy,
  openai_responses: openAIResponsesStrategy,
  anthropic_messages: anthropicMessagesStrategy,
  gemini_generate: geminiGenerateStrategy,
  dashscope_native: dashscopeNativeStrategy,
  openai_images: openAIImagesStrategy,
  gemini_image: geminiImageStrategy,
  qwen_image: qwenImageStrategy,
  grok_image: grokImageStrategy,
  zhipu_image: zhipuImageStrategy,
  anthropic_files: anthropicFilesStrategy,
  openai_files: openAIFilesStrategy,
};

/**
 * Returns the Strategy for a given kind. An unknown kind throws UnsupportedTransportError.
 *
 * Callers should check `isKnownTransportKind` and hide the model beforehand rather than relying on
 * this throw, which is a last line of defence.
 */
export function getStrategyByKind(kind: string, telemetry?: TelemetryPort): TransportStrategy {
  if (!isKnownTransportKind(kind)) {
    telemetry?.track('unknown_transport_kind', { kind });
    throw new UnsupportedTransportError(kind);
  }
  return STRATEGIES[kind];
}

/**
 * Returns the Strategy for AIModel.transport, or null when the model declares no transport, letting
 * the caller fall back to the older adapter.
 *
 * Unlike `getStrategyByKind` this never throws, which suits a staged migration where some models
 * carry a transport and some do not.
 */
export function getStrategyForModel(model: AIModel, telemetry?: TelemetryPort): TransportStrategy | null {
  const kind = (model as AIModel & { transport?: string }).transport;
  if (!kind) return null;
  if (!isKnownTransportKind(kind)) {
    telemetry?.track('unknown_transport_kind', { kind, modelId: model.id });
    return null;
  }
  return STRATEGIES[kind];
}

/**
 * Returns the Strategy for a transport kind, falling back to a default Strategy for unknown kinds.
 *
 * This is the shortcut used inside adapter sendMessageStream to pick a strategy from the metadata
 * transport:
 *   - a known kind is returned directly
 *   - an unknown kind reports telemetry and returns the fallback, without throwing, so the caller
 *     keeps working
 *
 * Unlike `getStrategyByKind` it does not throw, and unlike `getStrategyForModel` it takes a string,
 * which suits Relay and legacy adapters that have already resolved metadata before choosing a
 * strategy.
 */
export function resolveStrategyByKindOrFallback(
  kind: string | undefined,
  fallback: TransportStrategy,
  context?: { providerKind?: string; modelID?: string },
  telemetry?: TelemetryPort,
): TransportStrategy {
  if (!kind) return fallback;
  if (!isKnownTransportKind(kind)) {
    telemetry?.track('unknown_transport_kind', { kind, ...context });
    return fallback;
  }
  return STRATEGIES[kind];
}

/** The set of kinds this client knows, used to filter models (forward-compat). */
export function knownTransportKinds(): ReadonlySet<string> {
  return TRANSPORT_KIND_SET;
}

export { UnsupportedTransportError };
