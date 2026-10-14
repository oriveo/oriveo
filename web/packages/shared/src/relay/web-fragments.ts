/**
 * Connection-level web-search fragments of a relay (capability spec: RELAY x web search).
 *
 * Each connection stores one JSON object per protocol (not stored = that protocol's template); it is merged into the request body only while the chat web switch is on:
 * after the builder produces it and before the extra request body is attached. Only pure functions live here (template, validation, merge, referenced-profile derivation);
 * storage is local to each client, and the read-time mapping of the legacy fields is in `legacy-web-search.ts`.
 * Fixture: `shared/test-fixtures/relay/web-fragment.v1.json`.
 */

export type RelayWebTransport =
  | 'openai_chat_completions'
  | 'openai_responses'
  | 'anthropic_messages'
  | 'gemini_generate_content';

/** Order of the four segments on the settings page: Chat Completions / Responses / Messages / Gemini. */
export const RELAY_WEB_TRANSPORTS: readonly RelayWebTransport[] = [
  'openai_chat_completions',
  'openai_responses',
  'anthropic_messages',
  'gemini_generate_content',
];

export type RelayWebFragment = Record<string, unknown>;
export type RelayWebFragments = Partial<Record<RelayWebTransport, RelayWebFragment>>;

export const RELAY_WEB_FRAGMENT_TEMPLATES: Readonly<Record<RelayWebTransport, RelayWebFragment>> = {
  openai_responses: { tools: [{ type: 'web_search' }] },
  openai_chat_completions: { web_search_options: {} },
  // Base version: the newer tool needs an extra allowed_callers on models that do not support programmatic tool calling, otherwise 400.
  anthropic_messages: { tools: [{ type: 'web_search_20250305', name: 'web_search', max_uses: 5 }] },
  gemini_generate_content: { tools: [{ googleSearch: {} }] },
};

export const RELAY_WEB_FRAGMENT_MAX_BYTES = 8192;

/** A fragment must not rewrite the request skeleton or tool choice; reports the first matching key in this order. */
export const RELAY_WEB_FORBIDDEN_TOP_LEVEL_KEYS: readonly string[] = [
  'model',
  'messages',
  'input',
  'contents',
  'system',
  'systemInstruction',
  'system_instruction',
  'instructions',
  'stream',
  'stream_options',
  'previous_response_id',
  'tool_choice',
  'toolConfig',
  'tool_config',
];

const FUNCTION_TOOL_KEYS = ['functionDeclarations', 'function_declarations'];

export type RelayWebFragmentError =
  | 'not_json'
  | 'not_object'
  | 'empty'
  | 'too_large'
  | 'forbidden_key'
  | 'invalid_tools'
  | 'function_tool';

export type RelayWebFragmentValidation =
  | { ok: true; fragment: RelayWebFragment }
  | { ok: false; error: RelayWebFragmentError; key?: string };

export function isRelayWebTransport(value: unknown): value is RelayWebTransport {
  return typeof value === 'string' && (RELAY_WEB_TRANSPORTS as readonly string[]).includes(value);
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function isFunctionTool(tool: Record<string, unknown>): boolean {
  return tool.type === 'function' || FUNCTION_TOOL_KEYS.some((key) => key in tool);
}

/** Validation of the raw text in the edit box; for order and error codes see fixture validateCases. */
export function validateRelayWebFragment(raw: string): RelayWebFragmentValidation {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { ok: false, error: 'not_json' };
  }
  if (!isPlainObject(parsed)) return { ok: false, error: 'not_object' };
  if (Object.keys(parsed).length === 0) return { ok: false, error: 'empty' };
  if (new TextEncoder().encode(raw).length > RELAY_WEB_FRAGMENT_MAX_BYTES) return { ok: false, error: 'too_large' };
  const forbidden = RELAY_WEB_FORBIDDEN_TOP_LEVEL_KEYS.find((key) => key in parsed);
  if (forbidden) return { ok: false, error: 'forbidden_key', key: forbidden };
  if ('tools' in parsed) {
    const tools = parsed.tools;
    if (!Array.isArray(tools) || !tools.every(isPlainObject)) return { ok: false, error: 'invalid_tools' };
    if (tools.some(isFunctionTool)) return { ok: false, error: 'function_tool' };
  }
  return { ok: true, fragment: parsed };
}

/** Builder values win: only fills leaves the builder lacks, descending into objects level by level. */
function mergeBuilderWins(builder: unknown, fragment: unknown): unknown {
  if (builder === undefined) return structuredClone(fragment);
  if (isPlainObject(builder) && isPlainObject(fragment)) {
    const merged: Record<string, unknown> = { ...builder };
    for (const [key, value] of Object.entries(fragment)) merged[key] = mergeBuilderWins(builder[key], value);
    return merged;
  }
  return builder;
}

/**
 * Merge a fragment into the request body the builder has already assembled (written in place, returning the same body): `tools` is appended after the builder's tools
 * (when the Gemini builder already carries functionDeclarations the fragment's tools are not added at all), the other keys are deep-merged, and on leaf conflicts the builder wins.
 */
export function mergeRelayWebFragment(
  transport: RelayWebTransport,
  body: Record<string, unknown>,
  fragment: RelayWebFragment,
): Record<string, unknown> {
  for (const [key, value] of Object.entries(fragment)) {
    if (key === 'tools') {
      if (!Array.isArray(value)) continue;
      const existing = Array.isArray(body.tools) ? body.tools : [];
      const builderHasFunctions = transport === 'gemini_generate_content'
        && existing.some((tool) => isPlainObject(tool) && FUNCTION_TOOL_KEYS.some((name) => name in tool));
      if (builderHasFunctions) continue;
      body.tools = [...existing, ...structuredClone(value)];
      continue;
    }
    body[key] = mergeBuilderWins(body[key], value);
  }
  return body;
}

function toolsOf(fragment: RelayWebFragment): Record<string, unknown>[] {
  return Array.isArray(fragment.tools) ? fragment.tools.filter(isPlainObject) : [];
}

const GEMINI_SEARCH_TOOL_KEYS = ['googleSearch', 'google_search', 'googleSearchRetrieval', 'google_search_retrieval'];

/**
 * Not wired up: the Web relay path never had web-search reference (stream-shape) resolution, so this unit does not wire it, keeping only the derivation and passing the fixture.
 *
 * The web profile name used for reference resolution (a key of metadata `profiles.webSearch`), derived from the fragments actually merged this round;
 * null when it cannot be derived (or there are no fragments). Fixture citationCases.
 */
export function relayWebCitationProfile(
  transport: RelayWebTransport,
  fragment: RelayWebFragment | null | undefined,
): string | null {
  if (!fragment) return null;
  const tools = toolsOf(fragment);
  const toolType = (tool: Record<string, unknown>) => (typeof tool.type === 'string' ? tool.type : '');
  switch (transport) {
    case 'openai_responses':
      return tools.some((tool) => toolType(tool).startsWith('web_search')) ? 'oai_responses_web' : null;
    case 'anthropic_messages':
      return tools.some((tool) => toolType(tool).startsWith('web_search_')) ? 'ant_web_tool' : null;
    case 'gemini_generate_content':
      return tools.some((tool) => GEMINI_SEARCH_TOOL_KEYS.some((key) => key in tool)) ? 'gem_web' : null;
    case 'openai_chat_completions': {
      const plugins = Array.isArray(fragment.plugins) ? fragment.plugins.filter(isPlainObject) : [];
      if (plugins.some((plugin) => plugin.id === 'web')) return 'or_web';
      if ('web_search_options' in fragment) return 'oai_web_tool';
      if (tools.some((tool) => toolType(tool) === 'web_search')) return 'zhipu_web';
      return null;
    }
  }
}
