/**
 * Pure baseURL resolution for providers.
 * Web routes and the desktop main process share this one normalisation; it must not be forked.
 */

import { providerDefaults } from '@oriveo/config';
import type { ProviderKind } from '@oriveo/shared/pure-types';

/** Make sure the URL carries a scheme, and drop any trailing slash */
export function safeBase(raw: string | undefined, fallback: string): string {
  if (!raw) return fallback;
  const trimmed = raw.trim().replace(/\/+$/, '');
  if (!trimmed) return fallback;
  if (!/^https?:\/\//i.test(trimmed)) return `https://${trimmed}`;
  return trimmed;
}

/** Resolve the final baseURL for each provider; relay must supply an explicit endpoint. */
export function resolveProviderBaseURL(
  providerKind: ProviderKind,
  raw: string | undefined,
): string {
  switch (providerKind) {
    case 'openRouter':
      return safeBase(raw, providerDefaults.openRouter.defaultBaseURL);
    case 'deepseek':
      return safeBase(raw, providerDefaults.deepseek.defaultBaseURL);
    case 'mistral':
      return safeBase(raw, providerDefaults.mistral.defaultBaseURL);
    case 'grok':
      return safeBase(raw, providerDefaults.grok.defaultBaseURL);
    case 'openAI':
      return safeBase(raw, providerDefaults.openAI.defaultBaseURL);
    case 'anthropic':
      return safeBase(raw, providerDefaults.anthropic.defaultBaseURL);
    case 'gemini':
      return safeBase(raw, providerDefaults.gemini.defaultBaseURL);
    case 'groq':
      return safeBase(raw, providerDefaults.groq.defaultBaseURL);
    case 'togetherAI':
      return safeBase(raw, providerDefaults.togetherAI.defaultBaseURL);
    case 'fireworksAI':
      return safeBase(raw, providerDefaults.fireworksAI.defaultBaseURL);
    case 'miniMax':
      return safeBase(raw, providerDefaults.miniMax.defaultBaseURL);
    case 'zhipu':
      return safeBase(raw, providerDefaults.zhipu.defaultBaseURL);
    case 'qwen':
      return safeBase(raw, providerDefaults.qwen.defaultBaseURL);
    case 'moonshot':
      return safeBase(raw, providerDefaults.moonshot.defaultBaseURL);
    case 'siliconFlow':
      return safeBase(raw, providerDefaults.siliconFlow.defaultBaseURL);
    case 'relay':
      if (!raw || !raw.trim()) {
        throw new Error('Base URL is required for relay');
      }
      return safeBase(raw, raw);
    default:
      throw new Error(`Unsupported provider kind: ${providerKind}`);
  }
}
