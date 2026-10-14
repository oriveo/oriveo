"use client";

import Image from "next/image";
import type { RelayKind } from "@oriveo/shared";
import { useIsDarkTheme } from "../lib/hooks/useIsDarkTheme";
import { resolveOfficialProviderLogo } from "./provider-logo-assets";
import { resolveRelayConnectionAvatar } from "./relay-avatar";
import { useRelayAvatarChoice } from "../lib/hooks/useRelayAvatarChoice";
import { RelayAvatar, RelayWaypointsIcon } from "./RelayAvatar";
import styles from "./ProviderIcon.module.css";

interface ProviderIconProps {
  kind: string;
  size?: number;
  /** bare renders only the logo, with no container background, border or shadow, for small inline uses */
  bare?: boolean;
  /**
   * Local-engine connections only (localEngine): show the matching vendor logo by protocol type
   * (openai_compatible / codex_style -> OpenAI, anthropic_compatible -> Anthropic,
   * gemini_compatible -> Gemini, custom or nil -> the Relay icon).
   * Relay connections no longer draw a logo by protocol type.
   */
  relayKind?: RelayKind;
  /** Relay connection id (from relayIconSource): the key for the default icon and the on-device avatar choice; when absent only the base layer applies. */
  providerId?: string;
  /** Relay display name: relay connections resolve the unified avatar from it plus the address (relay-avatar.ts). */
  providerName?: string;
  /** Relay address: relay connections match a brand by its host. */
  baseURLText?: string;
  /** Local-engine connections only: model vendor / group hints used to infer the brand. Relay connections ignore model ids. */
  modelHints?: string[];
  /** Local-engine connection: with kind === 'relay' it skips the relay avatar and keeps the original inference. */
  localEngine?: boolean;
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

export function ProviderIcon({
  kind,
  size = 40,
  bare = false,
  relayKind,
  providerId,
  providerName,
  baseURLText,
  modelHints,
  localEngine,
  forceDark,
}: ProviderIconProps) {
  const systemDark = useIsDark();
  const isDark = forceDark ?? systemDark;
  const isRelayAvatar = kind === 'relay' && !localEngine;
  const avatarChoice = useRelayAvatarChoice(isRelayAvatar ? providerId : undefined);
  // Relay connections: one shared resolver everywhere, looking only at the connection id, name, address and on-device choice.
  if (isRelayAvatar) {
    return (
      <RelayAvatar
        avatar={resolveRelayConnectionAvatar({ providerId, name: providerName, baseURL: baseURLText, choice: avatarChoice })}
        size={size}
        forceDark={forceDark}
      />
    );
  }
  // Local engine: infer the brand from the name / model hints / protocol type; fall back to the Relay icon when nothing matches
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
