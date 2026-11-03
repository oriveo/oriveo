/**
 * Provider tint palette (aligned with iOS `ProviderTints.tint(for:)`).
 *
 * Used by donut slices, budget accent bars and micro dots that need a per-provider colour.
 * The same provider keeps the same colour across every view.
 *
 * providerKind naming: Web uses camelCase internally (openAI / anthropic / openRouter ...),
 * while server / mock data uses lowercase (openai / anthropic / openrouter ...).
 * Lookups match case-insensitively for both.
 */

import { providerTextTint as sharedProviderTextTint } from "@oriveo/shared";

// Source of truth shared by the three ends; keep in sync when changing:
// - iOS `OKLCHColor.swift` (iOS app) OriveoColorTokens.providerBrandHexes
// - Android `ProviderBrandColors.kt` (Android app)
export const TINTS: Record<string, string> = {
  openai: "#10a37f", // OpenAI green
  anthropic: "#c7956d", // Anthropic warm tan
  gemini: "#4285f4", // Google Gemini blue
  deepseek: "#4d6bfe", // DeepSeek blue-violet (was #3b6cd9, too dark)
  // Monochrome brand: follow the theme text color so the dot stays visible on dark surfaces.
  grok: "var(--o-text)",
  xai: "var(--o-text)", // alias of grok
  mistral: "#fa500f", // Mistral orange (brand colour)
  groq: "#f55036", // Groq red
  together: "#0ea5e9", // Together sky
  togetherai: "#0ea5e9",
  fireworks: "#ff6b35", // Fireworks orange
  fireworksai: "#ff6b35",
  minimax: "#e8457c", // MiniMax pink
  zhipu: "#1f63ec", // Zhipu blue
  qwen: "#615ced", // Qwen violet (was #6c63ff, too pale)
  moonshot: "#5b3aff", // Moonshot violet
  kimi: "#5b3aff", // alias of moonshot
  siliconflow: "#7c3aed", // SiliconFlow purple (was #0ea5ff, which is cyan and wrong)
  openrouter: "#6d63ff", // OpenRouter purple
  relay: "#64748b", // Relay slate
  // Note: `relay` is not in this table. Dashboards hash the providerId into RELAY_PALETTE so
  // multiple Relays do not all look grey; provider-kind icons (settings page) use a slate grey token.
};

/**
 * Relay instance palette (8 colours). Keeps multiple Relays distinguishable from each other.
 * Colours avoid the hue clusters of the mainstream brands (OpenAI green, Anthropic tan, blue-violet)
 * and use high-contrast Tailwind colours. Source of truth shared with iOS `relayPaletteHexes`
 * and Android `RELAY_PALETTE`.
 */
export const RELAY_PALETTE = [
  "#14b8a6", // teal 500
  "#f59e0b", // amber 500
  "#d946ef", // fuchsia 500
  "#84cc16", // lime 500
  "#ec4899", // pink 500
  "#eab308", // yellow 500
  "#fb923c", // orange 400
  "#0891b2", // cyan 600
];

export const FALLBACK_PALETTE = [
  "#6366f1", // indigo
  "#22c55e", // green
  "#f59e0b", // amber
  "#ef4444", // red
  "#06b6d4", // cyan
];

/**
 * Resolve the tint (HEX) for a providerKind / providerId.
 * Monochrome brands return a CSS variable instead of a hex; consumers must use it in CSS contexts only.
 * A known providerKind wins; otherwise the fallbackId is hashed (DJB2) into the fallback palette.
 * The hash matches iOS `OriveoColorTokens.fallbackPaletteIndex` and Android `djb2HashIndex`.
 */
export function providerTint(
  providerKind: string | undefined | null,
  fallbackId?: string | null,
): string {
  const key = providerKind?.trim().toLowerCase() ?? "";

  // Relay: the dashboard hashes each providerId into the 8-colour palette.
  // (Provider-kind icons such as the settings page use the slate grey token and do not call this.)
  if (key === "relay") {
    const seed = (fallbackId ?? key).toLowerCase();
    return RELAY_PALETTE[djb2Index(seed, RELAY_PALETTE.length)];
  }

  if (key && TINTS[key]) return TINTS[key];

  const seed = (fallbackId ?? providerKind ?? "").toLowerCase();
  if (!seed) return FALLBACK_PALETTE[0];
  return FALLBACK_PALETTE[djb2Index(seed, FALLBACK_PALETTE.length)];
}

/**
 * Text variant of `providerTint` (ring centre title and other brand-coloured text): same resolution,
 * last step swapped for the shared `providerTextTint`. Monochrome brands return their CSS variable as-is.
 */
export function providerTextTint(
  providerKind: string | undefined | null,
  fallbackId: string | null | undefined,
  isDark: boolean,
): string {
  const tint = providerTint(providerKind, fallbackId);
  return /^#[0-9a-f]{6}$/i.test(tint) ? sharedProviderTextTint(tint, isDark) : tint;
}

/** DJB2 stable hash -> palette index (matches iOS `djb2Index` and Android `djb2HashIndex`). */
function djb2Index(seed: string, count: number): number {
  if (!seed || count <= 0) return 0;
  let h = 5381;
  for (let i = 0; i < seed.length; i++) {
    h = ((h * 33) + seed.charCodeAt(i)) >>> 0;
  }
  return h % count;
}

/**
 * Combine a hex colour with an alpha (0-1) into an rgba string.
 * Used for translucent backgrounds, e.g. a chip background = tint at 14% alpha.
 */
export function withAlpha(hex: string, alpha: number): string {
  const m = /^#?([a-fA-F0-9]{6}|[a-fA-F0-9]{3})$/.exec(hex.trim());
  if (!m) return hex;
  let raw = m[1];
  if (raw.length === 3) {
    raw = raw
      .split("")
      .map((c) => c + c)
      .join("");
  }
  const r = parseInt(raw.slice(0, 2), 16);
  const g = parseInt(raw.slice(2, 4), 16);
  const b = parseInt(raw.slice(4, 6), 16);
  const a = Math.max(0, Math.min(1, alpha));
  return `rgba(${r}, ${g}, ${b}, ${a})`;
}
