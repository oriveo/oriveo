import type { Provider } from '@oriveo/shared';

/**
 * Relay avatar resolution (fixture `relay-avatar.v1.json`).
 * The model picker group header, chat top bar, message header, detail header and provider list all go through this one function; local connections do not.
 * It looks only at the display name and the address host; neither model id nor protocol type takes part (the old inference drew ordinary relays as OpenAI / Anthropic).
 */

export type RelayAvatarBrand = 'openrouter' | 'siliconflow' | 'together' | 'fireworks' | 'groq';

export type RelayAvatar =
  | { kind: 'brand'; brand: RelayAvatarBrand }
  | { kind: 'initial'; text: string }
  | { kind: 'generic' };

/** Built-in brand table, verbatim the same as the fixture; matched in order, first hit wins. New brands are added only to the fixture and here. */
export const RELAY_AVATAR_BRANDS: ReadonlyArray<{ id: RelayAvatarBrand; keywords: readonly string[] }> = [
  { id: 'openrouter', keywords: ['openrouter'] },
  { id: 'siliconflow', keywords: ['siliconflow'] },
  { id: 'together', keywords: ['together.ai', 'together.xyz', 'togetherai'] },
  { id: 'fireworks', keywords: ['fireworks'] },
  { id: 'groq', keywords: ['groq'] },
];

/** Any exclusion word hit skips brand matching (our own domain / name does not borrow an official brand). */
export const RELAY_AVATAR_EXCLUDE_KEYWORDS: readonly string[] = ['oriveo'];

/** Brand -> existing official logo asset (kind in provider-logo-assets). */
export const RELAY_AVATAR_BRAND_LOGO_KIND: Record<RelayAvatarBrand, string> = {
  openrouter: 'openRouter',
  siliconflow: 'siliconFlow',
  together: 'togetherAI',
  fireworks: 'fireworksAI',
  groq: 'groq',
};

function hostOf(baseURL: string | null | undefined): string {
  const raw = (baseURL ?? '').trim();
  if (!raw) return '';
  try {
    return new URL(raw.includes('://') ? raw : `https://${raw}`).hostname.toLowerCase();
  } catch {
    return '';
  }
}

const LETTER_OR_DIGIT = /[\p{L}\p{N}]/u;
const LATIN = /\p{Script=Latin}/u;

function initialOf(text: string): string | null {
  for (const char of Array.from(text)) {
    if (!LETTER_OR_DIGIT.test(char)) continue;
    return LATIN.test(char) ? char.toUpperCase() : char;
  }
  return null;
}

export function resolveRelayAvatar(input: { name?: string | null; baseURL?: string | null }): RelayAvatar {
  const name = (input.name ?? '').trim();
  const host = hostOf(input.baseURL);
  const haystacks = [name.toLowerCase(), host].filter(Boolean);
  const hits = (keyword: string) => haystacks.some((text) => text.includes(keyword));
  if (!RELAY_AVATAR_EXCLUDE_KEYWORDS.some(hits)) {
    const brand = RELAY_AVATAR_BRANDS.find((entry) => entry.keywords.some(hits));
    if (brand) return { kind: 'brand', brand: brand.id };
  }
  const initial = initialOf(name) ?? initialOf(host.replace(/^(api|www)\./, ''));
  return initial ? { kind: 'initial', text: initial } : { kind: 'generic' };
}

/** Stable marker of the render layer (data-relay-avatar), used by the five-place consistency assertion. */
export function relayAvatarMarker(avatar: RelayAvatar): string {
  if (avatar.kind === 'brand') return `brand:${avatar.brand}`;
  if (avatar.kind === 'initial') return `initial:${avatar.text}`;
  return 'generic';
}

/** Local engine connections do not go through avatar resolution and keep the original icon path. */
export function isLocalEngineConnection(provider: Pick<Provider, 'relayRequested'>): boolean {
  return Boolean(provider.relayRequested?.engineProfile);
}

export interface RelayIconSource {
  providerName?: string;
  baseURLText?: string;
  localEngine?: boolean;
}

/**
 * The name used for the avatar = the name the user gave (customName, same source on all platforms); if none, an empty string, and the fixture rule falls back to the host.
 * No fallback to the display name (that would draw the same "R" for every unnamed relay).
 */
export function relayAvatarName(provider: Pick<Provider, 'customName'>): string {
  return provider.customName?.trim() ?? '';
}

/**
 * Input to ProviderIcon for a relay: the name the user gave + the address; with no connection (session provider not found) it is empty -> generic.
 * Local connections pass only localEngine; the caller passes name and other inputs as before, keeping the original inference unchanged.
 */
export function relayIconSource(provider: Provider | null | undefined): RelayIconSource {
  if (!provider || provider.kind !== 'relay') return {};
  if (isLocalEngineConnection(provider)) return { localEngine: true };
  return {
    providerName: relayAvatarName(provider),
    baseURLText: provider.baseURLText ?? undefined,
    localEngine: false,
  };
}
