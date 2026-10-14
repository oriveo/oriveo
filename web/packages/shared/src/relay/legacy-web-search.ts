/**
 * The only decoding point for the legacy connection-level web-search declaration of a relay (two legacy fields; registered file for lint G9).
 *
 * The legacy fields are read only here:
 * - read-time mapping: when no fragment is stored locally, map the legacy fields in memory to a web-search fragment (not written back);
 * - when editing a connection they are carried over unchanged (they must not be cleared even though the old UI is gone);
 * - cleared when the web-search settings page is saved.
 * All other files go through the functions here and never touch these two fields directly. Fixture: web-fragment.v1.json legacyCases.
 */
import type { RelayRequestedConfig } from '../types/relay';
import {
  RELAY_WEB_FORBIDDEN_TOP_LEVEL_KEYS,
  RELAY_WEB_FRAGMENT_TEMPLATES,
  type RelayWebFragment,
  type RelayWebFragments,
  type RelayWebTransport,
} from './web-fragments';

/** [whether web search is declared, backend profile name]. */
const LEGACY_FIELDS = ['hasWebSearch', 'webSearchProfile'] as const;
type LegacyField = (typeof LEGACY_FIELDS)[number];
type LegacyWebSearchFields = Pick<RelayRequestedConfig, LegacyField>;

/** Lookup of metadata `profiles.webSearch[<name>]`; production passes the same-named lookup from metadata-client. */
export type RelayWebProfileLookup = (name: string) => { mergeParams?: Record<string, unknown> } | null | undefined;

/** Protocol that a legacy profile belongs to (fixture profileTransport). */
export const RELAY_LEGACY_WEB_PROFILE_TRANSPORT: Readonly<Record<string, RelayWebTransport>> = {
  oai_responses_web: 'openai_responses',
  grok_responses_web: 'openai_responses',
  ant_web_tool: 'anthropic_messages',
  gem_web: 'gemini_generate_content',
  gem_web_retrieval: 'gemini_generate_content',
  or_web: 'openai_chat_completions',
  qwen_web: 'openai_chat_completions',
  zhipu_web: 'openai_chat_completions',
  oai_web_tool: 'openai_chat_completions',
  kimi_web_search: 'openai_chat_completions',
};

/** Profiles that need a client-side tool loop for web search: the merged fields alone cannot send it, so no mapping. */
const TOOL_LOOP_PROFILES: ReadonlySet<string> = new Set(['kimi_web_search']);

function legacyFieldsOf(requested: RelayRequestedConfig | null | undefined): LegacyWebSearchFields {
  const [flag, profile] = LEGACY_FIELDS;
  return { [flag]: requested?.[flag], [profile]: requested?.[profile] };
}

function withoutForbiddenKeys(params: Record<string, unknown>): RelayWebFragment {
  return Object.fromEntries(
    Object.entries(params).filter(([key]) => !RELAY_WEB_FORBIDDEN_TOP_LEVEL_KEYS.includes(key)),
  );
}

/** Read-time mapping of the legacy fields (used only when there is no stored fragment); the result is never written back. */
export function legacyRelayWebFragments(
  requested: RelayRequestedConfig | null | undefined,
  lookupProfile: RelayWebProfileLookup,
): RelayWebFragments {
  const [flag, profileKey] = LEGACY_FIELDS;
  const legacy = legacyFieldsOf(requested);
  if (legacy[flag] !== true) return {};
  const profile = legacy[profileKey]?.trim();
  const definition = profile ? lookupProfile(profile) : undefined;
  const transport = profile ? RELAY_LEGACY_WEB_PROFILE_TRANSPORT[profile] : undefined;
  // The profile exists in metadata but not in the protocol table: it is unknown which protocol it belongs to, so no mapping.
  if (profile && definition && !transport) return {};
  if (profile && definition && transport) {
    if (TOOL_LOOP_PROFILES.has(profile)) return {};
    const params = withoutForbiddenKeys(definition.mergeParams ?? {});
    return Object.keys(params).length > 0 ? { [transport]: structuredClone(params) } : {};
  }
  // No profile, or the profile is not in metadata: the existing builders can only send web search on Responses and Gemini.
  const toolName = requested?.webSearchToolName ?? 'web_search';
  return {
    ...(toolName !== 'disabled' ? { openai_responses: { tools: [{ type: toolName }] } } : {}),
    gemini_generate_content: structuredClone(RELAY_WEB_FRAGMENT_TEMPLATES.gemini_generate_content),
  };
}

/** Effective fragments: if storage has any segment use only storage, otherwise map the legacy fields in memory. */
export function effectiveRelayWebFragments(
  stored: RelayWebFragments,
  requested: RelayRequestedConfig | null | undefined,
  lookupProfile: RelayWebProfileLookup,
): RelayWebFragments {
  if (Object.keys(stored).length > 0) return stored;
  return legacyRelayWebFragments(requested, lookupProfile);
}

/** When editing a connection / changing the connection type, carry the two legacy fields and the legacy web-search tool name (used only for mapping in this file) unchanged onto the new config. */
export function carryLegacyWebSearchFields(
  preserve: RelayRequestedConfig | null | undefined,
): LegacyWebSearchFields & Pick<RelayRequestedConfig, 'webSearchToolName'> {
  return { ...legacyFieldsOf(preserve), webSearchToolName: preserve?.webSearchToolName };
}

export function hasLegacyWebSearchFields(requested: RelayRequestedConfig | null | undefined): boolean {
  const fields = legacyFieldsOf(requested);
  return LEGACY_FIELDS.some((key) => fields[key] !== undefined);
}

/** Clear the two legacy fields when the web-search settings page is saved (other fields unchanged). */
export function clearLegacyWebSearchFields(requested: RelayRequestedConfig): RelayRequestedConfig {
  const next: RelayRequestedConfig = { ...requested };
  for (const key of LEGACY_FIELDS) delete next[key];
  return next;
}
