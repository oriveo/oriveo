"use client";

import Image from "next/image";
import type { RelayKind } from "@oriveo/shared";
import { useIsDarkTheme } from "../lib/hooks/useIsDarkTheme";
import { resolveOfficialProviderLogo } from "./provider-logo-assets";
import styles from "./ProviderIcon.module.css";

interface ProviderIconProps {
  kind: string;
  size?: number;
  /** bare renders only the logo, with no container background, border or shadow, for small inline uses */
  bare?: boolean;
  /**
   * When kind === 'relay', show the brand logo matching the protocol the user selected:
   * - openai_compatible / codex_style → OpenAI
   * - anthropic_compatible → Anthropic
   * - gemini_compatible → Gemini
   * - custom or nil → the Relay logo
   *
   * The same rule applies in the conversation list and in the chat TopBar.
   */
  relayKind?: RelayKind;
  /** Relay/custom provider name, used to pick a closer brand logo when possible. */
  providerName?: string;
  /** Relay/custom provider base URL, used to pick a closer brand logo when possible. */
  baseURLText?: string;
  /** Relay/custom provider model vendor/group keys, used to pick a closer brand logo when possible. */
  modelHints?: string[];
  /**
   * Force the dark appearance of the logo, always using the darkLogo variant.
   * Used by brand cards on a dark background such as ProviderHeroCard and
   * ProviderDetailBrandHero, which show the white brand logo whatever the system theme is.
   */
  forceDark?: boolean;
}

/** Relay protocol type → BRAND_CONFIG key. Anything not listed falls back to the Relay logo */
const RELAY_KIND_TO_BRAND: Partial<Record<RelayKind, string>> = {
  openai_compatible: "openAI",
  codex_style: "openAI",
  anthropic_compatible: "anthropic",
  gemini_compatible: "gemini",
};

const RELAY_BRAND_HINTS: Array<{ brand: string; patterns: RegExp[] }> = [
  { brand: "moonshot", patterns: [/\bkimi\b/i, /moonshot/i, /moonshot\.ai/i, /moonshot\.cn/i] },
  { brand: "grok", patterns: [/\bgrok\b/i, /\bxai\b/i, /\bx\.ai\b/i] },
  { brand: "openRouter", patterns: [/openrouter/i] },
  { brand: "openAI", patterns: [/openai/i, /\bgpt\b/i, /\bo\d(?:-|$)/i, /chatgpt/i] },
  { brand: "anthropic", patterns: [/anthropic/i, /claude/i] },
  { brand: "gemini", patterns: [/gemini/i, /google/i, /generativelanguage/i] },
  { brand: "deepseek", patterns: [/deepseek/i] },
  { brand: "mistral", patterns: [/mistral/i, /magistral/i, /codestral/i, /mixtral/i, /devstral/i, /ministral/i, /pixtral/i] },
  { brand: "qwen", patterns: [/\bqwen\b/i, /dashscope/i, /aliyun/i, /alibaba/i] },
  { brand: "groq", patterns: [/\bgroq\b/i] },
  { brand: "togetherAI", patterns: [/together/i] },
  { brand: "fireworksAI", patterns: [/fireworks/i] },
  { brand: "miniMax", patterns: [/minimax/i, /minimaxi/i] },
  { brand: "zhipu", patterns: [/zhipu/i, /\bz\.ai\b/i, /bigmodel/i, /\bglm\b/i] },
  { brand: "siliconFlow", patterns: [/siliconflow/i] },
];

function resolveRelayBrandFromHints(values: Array<string | undefined>): string | undefined {
  const text = values.filter(Boolean).join(" ");
  if (!text) return undefined;
  return RELAY_BRAND_HINTS.find((entry) => entry.patterns.some((pattern) => pattern.test(text)))?.brand;
}

// Oriveo / Relay are app-owned marks. Official providers resolve through
// provider-logo-assets.ts so every Web App surface uses the same artwork.
const BRAND_CONFIG: Record<
  string,
  {
    logo: string;
    darkLogo?: string;
  }
> = {
  // Relay custom endpoints: the Orbit Relay purple and orange brand logo.
  // Used when the modelID does not imply a family (OpenAI/Anthropic/Gemini); when it does, the matching brand logo wins.
  relay: {
    logo: "/providers/relay.svg",
  },
};

// Shared dark theme subscription behind a single global MutationObserver, rather than one per instance, which slowed HMR down once 30 or more piled up
const useIsDark = useIsDarkTheme;

/**
 * Fallback icon for relay endpoints, drawn as a path of waypoints.
 *
 * Three dots joined by thin lines into a triangular path, plus a short line at the top for the
 * incoming data, conveying data flowing through a relay node. The same shape as the SF Symbol
 * `point.3.connected.trianglepath.dotted` and the Material `Hub` icon.
 */
function RelayWaypointsIcon({ size, className }: { size: number; className?: string }) {
  return (
    <svg
      className={className}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {/* Connecting path lines */}
      <path d="M7.5 6.5l9 0M7.5 6.5l-3 11M16.5 6.5l3 11M5.5 17.5l13 0" opacity="0.55" />
      {/* Nodes, drawn as filled circles */}
      <circle cx="7.5" cy="6.5" r="2" fill="currentColor" stroke="none" />
      <circle cx="16.5" cy="6.5" r="2" fill="currentColor" stroke="none" />
      <circle cx="5" cy="17.5" r="2" fill="currentColor" stroke="none" />
      <circle cx="19" cy="17.5" r="2" fill="currentColor" stroke="none" />
      <circle cx="12" cy="12" r="1.4" fill="currentColor" stroke="none" />
    </svg>
  );
}

export function ProviderIcon({
  kind,
  size = 40,
  bare = false,
  relayKind,
  providerName,
  baseURLText,
  modelHints,
  forceDark,
}: ProviderIconProps) {
  const systemDark = useIsDark();
  const isDark = forceDark ?? systemDark;
  // Relay path: map the protocol the user selected to a brand logo; custom and nil fall back to the Relay logo
  const resolvedKind = (() => {
    if (kind !== 'relay') return kind;
    const hintedBrand = resolveRelayBrandFromHints([providerName, baseURLText, ...(modelHints ?? [])]);
    if (hintedBrand) return hintedBrand;
    if (!relayKind) return kind;
    return RELAY_KIND_TO_BRAND[relayKind] ?? kind;
  })();
  const config = BRAND_CONFIG[resolvedKind];
  const officialLogo = resolveOfficialProviderLogo(resolvedKind, isDark);

  // relay, or an unknown provider, falls back to the Relay "waypoints" icon, which conveys a relay node
  if (!officialLogo && !config) {
    if (bare) {
      return <RelayWaypointsIcon size={size} className={styles.bareFallback} />;
    }
    return (
      <div
        className={styles.fallback}
        style={{ width: size, height: size, borderRadius: size * 0.28 }}
      >
        <RelayWaypointsIcon size={size * 0.5} />
      </div>
    );
  }

  const logoSrc = officialLogo ?? (isDark && config?.darkLogo ? config.darkLogo : config!.logo);

  // Native transparent artwork: no tray, border, shadow, or rounded clipping.
  return (
    <Image
      className={styles.bareLogo}
      src={logoSrc}
      alt=""
      width={size}
      height={size}
      draggable={false}
    />
  );
}
