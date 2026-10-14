import type { Provider } from '@oriveo/shared';

/**
 * Relay avatar resolution (fixture `relay-avatar.v1.json`).
 * The model picker group header, chat top bar, message header, detail header and provider list all go through this one function; local connections do not.
 * It looks only at the display name and the address host; neither model id nor protocol type takes part (the old inference drew ordinary relays as OpenAI / Anthropic).
 */

export type RelayAvatarBrand = 'openrouter' | 'siliconflow' | 'together' | 'fireworks' | 'groq';

export type RelayAvatarIconId =
  | 'planet'
  | 'compass'
  | 'sailboat'
  | 'lighthouse'
  | 'mountains'
  | 'sun-horizon'
  | 'flame'
  | 'tree-evergreen'
  | 'moon-stars'
  | 'butterfly';

export type RelayAvatar =
  | { kind: 'brand'; brand: RelayAvatarBrand }
  | { kind: 'icon'; icon: RelayAvatarIconId }
  | { kind: 'initial'; text: string }
  | { kind: 'generic' };

/**
 * Default avatar icon table (`icons` in fixture `relay-avatar-icon.v1.json`); the order is both the modulo index and the sheet cell order.
 * `palette` is the color name from the fixture; the render layer maps it to existing color tokens (dark 400 / light 600 by theme), never a hex value.
 */
export const RELAY_AVATAR_ICONS: ReadonlyArray<{ id: RelayAvatarIconId; phosphor: string; palette: string }> = [
  { id: 'planet', phosphor: 'planet', palette: 'detailRow.indigo' },
  { id: 'compass', phosphor: 'compass', palette: 'detailRow.teal' },
  { id: 'sailboat', phosphor: 'sailboat', palette: 'detailRow.cyan' },
  { id: 'lighthouse', phosphor: 'lighthouse', palette: 'capability.attachment' },
  { id: 'mountains', phosphor: 'mountains', palette: 'capability.webSearch' },
  { id: 'sun-horizon', phosphor: 'sun-horizon', palette: 'detailRow.orange' },
  { id: 'flame', phosphor: 'flame', palette: 'detailRow.rose' },
  { id: 'tree-evergreen', phosphor: 'tree-evergreen', palette: 'capability.vision' },
  { id: 'moon-stars', phosphor: 'moon-stars', palette: 'capability.reasoning' },
  { id: 'butterfly', phosphor: 'butterfly', palette: 'capability.tools' },
];

/** The on-device choice value that means "initial" (fixture `letterChoice`). */
export const RELAY_AVATAR_LETTER_CHOICE = 'letter';

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

/** Brand cell label: the brand display name, never translated. */
export const RELAY_AVATAR_BRAND_DISPLAY_NAME: Record<RelayAvatarBrand, string> = {
  openrouter: 'OpenRouter',
  siliconflow: 'SiliconFlow',
  together: 'Together AI',
  fireworks: 'Fireworks AI',
  groq: 'Groq',
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

type RelayAvatarBaseInput = { name?: string | null; baseURL?: string | null };

function baseBrand(input: RelayAvatarBaseInput): RelayAvatarBrand | null {
  const name = (input.name ?? '').trim();
  const host = hostOf(input.baseURL);
  const haystacks = [name.toLowerCase(), host].filter(Boolean);
  const hits = (keyword: string) => haystacks.some((text) => text.includes(keyword));
  if (RELAY_AVATAR_EXCLUDE_KEYWORDS.some(hits)) return null;
  return RELAY_AVATAR_BRANDS.find((entry) => entry.keywords.some(hits))?.id ?? null;
}

/** Base-layer initial rule (no brand matching): the first letter / digit of the trimmed name, otherwise of the host without api. / www. */
export function relayAvatarInitial(input: RelayAvatarBaseInput): string | null {
  const name = (input.name ?? '').trim();
  return initialOf(name) ?? initialOf(hostOf(input.baseURL).replace(/^(api|www)\./, ''));
}

/** Base layer (relay-avatar.v1.json): brand -> initial -> generic. The final avatar of a relay connection goes through `resolveRelayConnectionAvatar`. */
export function resolveRelayAvatar(input: RelayAvatarBaseInput): RelayAvatar {
  const brand = baseBrand(input);
  if (brand) return { kind: 'brand', brand };
  const initial = relayAvatarInitial(input);
  return initial ? { kind: 'initial', text: initial } : { kind: 'generic' };
}

const ASCII_WHITESPACE = /^[\t\n\v\f\r ]+|[\t\n\v\f\r ]+$/g;

/** Default icon: trim ASCII whitespace from the connection id, lowercase ASCII letters, hash the UTF-8 bytes with FNV-1a 32 and take it modulo the icon count. */
export function relayAvatarDefaultIcon(providerId: string): RelayAvatarIconId {
  const key = providerId.replace(ASCII_WHITESPACE, '').replace(/[A-Z]/g, (char) => char.toLowerCase());
  let hash = 0x811c9dc5;
  for (const byte of new TextEncoder().encode(key)) {
    hash = Math.imul(hash ^ byte, 0x01000193) >>> 0;
  }
  return RELAY_AVATAR_ICONS[hash % RELAY_AVATAR_ICONS.length].id;
}

function iconChoice(choice: string | null | undefined): RelayAvatarIconId | null {
  return RELAY_AVATAR_ICONS.find((icon) => icon.id === choice)?.id ?? null;
}

export interface RelayConnectionAvatarInput extends RelayAvatarBaseInput {
  providerId?: string | null;
  /** On-device choice (icon id / "letter"); any other value is ignored. */
  choice?: string | null;
}

/**
 * Final avatar of a relay connection (fixture relay-avatar-icon.v1.json): on-device choice -> base-layer brand -> default icon assigned by connection id.
 * With an empty connection id the base-layer result is returned as is.
 */
export function resolveRelayConnectionAvatar(input: RelayConnectionAvatarInput): RelayAvatar {
  const base = resolveRelayAvatar(input);
  const providerId = input.providerId ?? '';
  if (!providerId) return base;
  const chosenIcon = iconChoice(input.choice);
  if (chosenIcon) return { kind: 'icon', icon: chosenIcon };
  if (input.choice === RELAY_AVATAR_LETTER_CHOICE) {
    const initial = relayAvatarInitial(input);
    if (initial) return { kind: 'initial', text: initial };
    return { kind: 'icon', icon: relayAvatarDefaultIcon(providerId) };
  }
  if (base.kind === 'brand') return base;
  return { kind: 'icon', icon: relayAvatarDefaultIcon(providerId) };
}

export type RelayAvatarPickerCell =
  | { kind: 'brand'; brand: RelayAvatarBrand }
  | { kind: 'icon'; icon: RelayAvatarIconId }
  | { kind: 'letter'; text: string };

/** Sheet cells: brand (only when the base layer matches a brand) -> the ten icons -> initial (only when the initial rule yields one). */
export function relayAvatarPickerCells(input: RelayAvatarBaseInput): RelayAvatarPickerCell[] {
  const cells: RelayAvatarPickerCell[] = [];
  const brand = baseBrand(input);
  if (brand) cells.push({ kind: 'brand', brand });
  for (const icon of RELAY_AVATAR_ICONS) cells.push({ kind: 'icon', icon: icon.id });
  const initial = relayAvatarInitial(input);
  if (initial) cells.push({ kind: 'letter', text: initial });
  return cells;
}

/** Cell marker (as written in fixture pickerCases.cells): `brand:<id>` / `<icon id>` / `letter:<text>`. */
export function relayAvatarPickerCellMarker(cell: RelayAvatarPickerCell): string {
  if (cell.kind === 'brand') return `brand:${cell.brand}`;
  if (cell.kind === 'letter') return `letter:${cell.text}`;
  return cell.icon;
}

/** On-device choice for a cell: brand cell = remove (null), icon cell = icon id, initial cell = "letter". */
export function relayAvatarPickerCellChoice(cell: RelayAvatarPickerCell): string | null {
  if (cell.kind === 'brand') return null;
  if (cell.kind === 'letter') return RELAY_AVATAR_LETTER_CHOICE;
  return cell.icon;
}

/** Which cell the current avatar falls on (selected state). */
export function relayAvatarPickerCellSelected(cell: RelayAvatarPickerCell, avatar: RelayAvatar): boolean {
  if (cell.kind === 'brand') return avatar.kind === 'brand' && avatar.brand === cell.brand;
  if (cell.kind === 'letter') return avatar.kind === 'initial';
  return avatar.kind === 'icon' && avatar.icon === cell.icon;
}

/** Stable marker of the render layer (data-relay-avatar), used by the five-place consistency assertion. */
export function relayAvatarMarker(avatar: RelayAvatar): string {
  if (avatar.kind === 'brand') return `brand:${avatar.brand}`;
  if (avatar.kind === 'icon') return `icon:${avatar.icon}`;
  if (avatar.kind === 'initial') return `initial:${avatar.text}`;
  return 'generic';
}

/** Local engine connections do not go through avatar resolution and keep the original icon path. */
export function isLocalEngineConnection(provider: Pick<Provider, 'relayRequested'>): boolean {
  return Boolean(provider.relayRequested?.engineProfile);
}

export interface RelayIconSource {
  /** Connection id: the key for the default icon and the on-device choice; absent when there is no connection -> base-layer result. */
  providerId?: string;
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

/** Input for the detail header change-icon sheet: connection id + the name the user gave + the address (same source as relayIconSource). */
export interface RelayAvatarSource {
  providerId: string;
  name: string;
  baseURL?: string;
}

export function relayAvatarSource(provider: Pick<Provider, 'id' | 'customName' | 'baseURLText'>): RelayAvatarSource {
  return { providerId: provider.id, name: relayAvatarName(provider), baseURL: provider.baseURLText ?? undefined };
}

/**
 * Input to ProviderIcon for a relay: the name the user gave + the address; with no connection (session provider not found) it is empty -> generic.
 * Local connections pass only localEngine; the caller passes name and other inputs as before, keeping the original inference unchanged.
 */
export function relayIconSource(provider: Provider | null | undefined): RelayIconSource {
  if (!provider || provider.kind !== 'relay') return {};
  if (isLocalEngineConnection(provider)) return { localEngine: true };
  return {
    providerId: provider.id,
    providerName: relayAvatarName(provider),
    baseURLText: provider.baseURLText ?? undefined,
    localEngine: false,
  };
}
