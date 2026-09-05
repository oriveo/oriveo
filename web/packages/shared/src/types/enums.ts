/* ── Provider ─────────────────────────────────────────── */

export const PROVIDER_KINDS = [
  "openAI",
  "anthropic",
  "gemini",
  "openRouter",
  "deepseek",
  "grok",
  "mistral",
  "groq",
  "togetherAI",
  "fireworksAI",
  "miniMax",
  "zhipu",
  "qwen",
  "moonshot",
  "siliconFlow",
  "relay",
] as const;

export type ProviderKind = (typeof PROVIDER_KINDS)[number];

export function isValidProviderKind(kind: string): kind is ProviderKind {
  return (PROVIDER_KINDS as readonly string[]).includes(kind);
}

/** Aggregated (catalog) providers: everything except user relay. */
export function isAggregatedProvider(kind: ProviderKind): boolean {
  return kind !== "relay";
}

/**
 * Whether a provider's model list arrives in an order chosen upstream that the UI must preserve.
 * No provider does today, so the list is always sorted locally.
 */
export function usesServerOrderedModels(_kind: ProviderKind): boolean {
  return false;
}

export type ProviderConnectionState =
  | { kind: "connected" }
  | { kind: "syncing" }
  | { kind: "issue"; message: string };

/* ── Model ────────────────────────────────────────────── */

export type ModelCapability =
  | "reasoning"
  | "text"
  | "image"
  | "video"
  | "file"
  | "web"
  | "imageGeneration";

export type ReasoningMode = "automatic" | "fast" | "balanced" | "deep" | "max";

/* ── Chat ─────────────────────────────────────────────── */

export type ChatRole = "user" | "assistant" | "system";

export type ChatMessageState =
  | "delivered"
  | "generating"
  | "interrupted"
  | "failed";

/**
 *  
 *   ProviderError.kind  
 */
export type ProviderErrorSource = "provider" | "network" | "oriveo" | "desktop" | "unknown";

export type AttachmentKind = "image" | "video" | "file";

/* ── Auth ─────────────────────────────────────────────── */

export type LoginMethod = "apple" | "google" | "email";

/* ── Preferences ──────────────────────────────────────── */

export type ThemeOption = "system" | "light" | "dark";

export type SendShortcut = "cmdEnter" | "enter";

export type LanguageOption =
  | "system"
  | "en"
  | "zh-Hans"
  | "zh-Hant"
  | "ja"
  | "ko"
  | "es"
  | "fr"
  | "de"
  | "pt-BR"
  | "ar"
  | "hi"
  | "id"
  | "vi"
  | "th"
  | "tr"
  | "ru";

/* ── Navigation ───────────────────────────────────────── */

export type AppTab = "home" | "providers" | "settings";
