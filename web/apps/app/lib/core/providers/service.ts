/**
 * Unified provider service - ChatView and ProviderSetup call these functions
 * and never care about the underlying provider differences.
 */

import type { ProviderKind, AIModel } from '@oriveo/shared';
import type { StreamUsage, ContentPart, SyncResult, StreamHandle, StreamOptions } from './types';
import { getAdapter } from './registry';
import {
  USE_PROXY,
  sendStreamProxy,
  validateKeyProxy,
  validateRelayKeyProxy,
  type KeyValidationResult,
} from './proxy-client';
import {
  getMetadataSnapshot,
  initMetadata,
  resolveCatalogModel,
} from '../metadata/metadata-client';
import { isMoonshotChinaBaseURL } from './adapters/moonshot';
import { IS_DESKTOP, sendStreamDesktop } from './desktop-stream';

/* ── Key Validation ──────────────────────────────────── */

export type { KeyValidationResult } from './proxy-client';

/**
 * Validate a Relay (custom endpoint) key. Keeps throw-on-error semantics, since there is no
 * metadata contract to make a three-state decision from.
 */
export async function validateProviderKey(
  kind: ProviderKind,
  apiKey: string,
  baseURL?: string,
): Promise<void> {
  if (kind !== 'relay') {
    if (!apiKey.trim()) {
      throw new Error('Missing API key.');
    }
    return;
  }
  if (USE_PROXY) {
    return validateRelayKeyProxy(apiKey, baseURL);
  }
  return getAdapter(kind).validateKey(apiKey, baseURL);
}

/**
 * Validate an official provider key through the Next runtime proxy probe, returning a three-state
 * result (innocent until proven guilty).
 *
 * Never throws for a decision (invalid is a normal return value); a network error or a
 * non-browser environment always maps to unverified.
 */
export async function validateOfficialProviderKey(
  kind: ProviderKind,
  apiKey: string,
  baseURL?: string,
): Promise<KeyValidationResult> {
  if (!apiKey.trim()) {
    return 'unverified';
  }
  // Validation relies on the Next runtime proxy (CORS). Without a window (SSR, tests) there is nothing to probe, so the result is unverified.
  if (!USE_PROXY) {
    return 'unverified';
  }
  return validateKeyProxy(kind, apiKey, baseURL);
}

/* ── Model Sync ──────────────────────────────────────── */

/**
 * Kept only for Relay catalog sync, where the catalog comes from the user's own custom endpoint.
 *
 * @deprecated Official providers must not call this to fetch a catalog. The official catalog is
 * authoritative in the backend metadata, so use `buildOfficialEnabledModels()` to build the
 * enabled models from metadata instead.
 */
export async function syncProviderModels(
  kind: ProviderKind,
  apiKey: string,
  baseURL?: string,
): Promise<SyncResult> {
  if (kind !== 'relay') {
    if (!apiKey.trim()) {
      throw new Error('Missing API key.');
    }
    await initMetadata().catch(() => {});
    const metadata = getMetadataSnapshot();
    const provider = metadata?.providers[kind];
    const models: AIModel[] = provider
      ? Object.values(provider.models)
        .sort((left, right) => {
          const rankDiff = (right.uiHints?.rank ?? 0) - (left.uiHints?.rank ?? 0);
          if (rankDiff !== 0) return rankDiff;
          return (left.displayName ?? left.canonicalModelId ?? '').localeCompare(
            right.displayName ?? right.canonicalModelId ?? '',
            undefined,
            {
              numeric: true,
              sensitivity: 'base',
            },
          );
        })
        .map((model) => {
          const id = model.canonicalModelId ?? model.displayName ?? '';
          return {
            id,
            canonicalModelId: model.canonicalModelId,
            name: model.displayName ?? id,
            capabilities: (model.capabilities ?? ['text']) as AIModel['capabilities'],
            reasoningModeAvailable: Boolean(model.profiles?.reasoning),
            isAvailable: true,
            isDefault: id === provider.defaultModelId,
            isRecommended: Boolean(model.uiHints?.recommended),
            priceTier: '',
            summary: undefined,
            groupKey: model.uiHints?.groupKey,
            groupName: model.uiHints?.groupName,
            sortRank: model.uiHints?.rank,
            badgeOrder: model.uiHints?.badgeOrder as AIModel['badgeOrder'],
            promptPrice: typeof model.pricing?.promptPerMToken === 'number'
              ? model.pricing.promptPerMToken / 1_000_000
              : undefined,
            completionPrice: typeof model.pricing?.completionPerMToken === 'number'
              ? model.pricing.completionPerMToken / 1_000_000
              : undefined,
            contextLength: model.contextLength,
            reasoningProfile: model.profiles?.reasoning ?? undefined,
            webSearchProfile: model.profiles?.webSearch ?? undefined,
            imageGenProfile: model.profiles?.imageGen ?? undefined,
            generationProfile: model.profiles?.generation ?? undefined,
          };
        })
      : [];
    return { models, recommended: models.filter((model) => model.isRecommended).slice(0, 6) };
  }
  return getAdapter(kind).syncModels(apiKey, baseURL);
}

/* ── Streaming Chat ──────────────────────────────────── */

/**
 * Resolve the webSearch profile name of a model.
 * Metadata is authoritative and takes precedence; when it is missing this returns undefined and
 * the adapter falls back to its default web behavior.
 */
function resolveWebSearchProfileName(
  kind: ProviderKind,
  modelID: string,
): string | undefined {
  try {
    return resolveCatalogModel(modelID, kind)?.profiles.webSearch;
  } catch {
    return undefined;
  }
}

export function sendStream(
  kind: ProviderKind,
  apiKey: string,
  modelID: string,
  messages: { role: 'user' | 'assistant' | 'system'; content: string | ContentPart[] }[],
  baseURL?: string,
  options?: StreamOptions,
): StreamHandle {
  // Desktop: official and relay providers stream through main over IPC (MessagePort plus real
  // cross-process cancellation). apiKey here is already a keyRef (partition-scoped; the plaintext
  // stays in the key vault and never crosses IPC). Relay goes through RelayChatStreamRequest and
  // sendDesktopRelayStream in main, connecting directly over undici with no CORS concerns and
  // without the /api/relay/forward reverse proxy. Free still talks to the backend directly.
  // On web IS_DESKTOP is always false, so behavior is unchanged.
  if (IS_DESKTOP) {
    return sendStreamDesktop(kind, apiKey, modelID, messages, baseURL, options);
  }
  if (USE_PROXY && kind !== 'relay' && !shouldUseBrowserDirectStream(kind, baseURL)) {
    return sendStreamProxy(kind, apiKey, modelID, messages, baseURL, options);
  }
  const webSearchProfileName = options?.supportsWebSearch
    ? resolveWebSearchProfileName(kind, modelID)
    : undefined;
  return getAdapter(kind).sendStream(
    apiKey,
    modelID,
    messages,
    baseURL,
    options,
    webSearchProfileName,
  );
}

function shouldUseBrowserDirectStream(kind: ProviderKind, baseURL?: string): boolean {
  return kind === 'moonshot' && isMoonshotChinaBaseURL(baseURL);
}

/* ── Cost Estimation ─────────────────────────────────── */

export { estimateCost } from '../chat/cost';

/* ── Re-exports for consumers ────────────────────────── */

export type { SyncResult, StreamHandle, StreamEvent, StreamUsage, ContentPart, StreamOptions } from './types';
// Backward-compatible alias.
export type { StreamUsage as OpenRouterUsage } from './types';
