import { providerDefaults } from '@oriveo/config';
import type { ProviderKind, ReasoningMode } from '@oriveo/shared/pure-types';
import type { ProviderTransportDefinition } from '../../metadata/types';
import type { ContentPart } from '../types';
import type { RelayRuntimeConfig } from '../../ports';
import { resolveProviderBaseURL } from '../url-utils';
// The single source of truth for the Provider key validation contract is ../key-validation.
import type { ProviderValidationContract } from '../key-validation';
import type { GenerationParameterProfile, GenerationParameterValue } from './types';
import type { CapabilityRuntimeEnvelope, RuntimeCapabilityModel } from './capability-execution';
import type { ContinuationIntent } from '../request-preference/continuation';

// Re-exported so metadata types and the apps/app runtime shell can pass it through with `export *`.
export type { InvalidKeySignal, ProviderValidationContract } from '../key-validation';

type JSONObject = Record<string, unknown>;

export interface ProxyMessage {
  role: 'user' | 'assistant' | 'system' | 'tool';
  content: string | ContentPart[];
  /** Chat Completions agent leg: assistant requests one or more local tools. */
  tool_calls?: ProxyToolCall[];
  /** Chat Completions agent leg: associates a tool result with its request. */
  tool_call_id?: string;
  /** Provider-owned continuation captured from the immediately preceding agent leg. Local-only
   * between the Web client and Oriveo request compiler; the wire adapter maps it by protocol. */
  providerContinuation?: ContinuationIntent;
}

export interface ProxyToolCall {
  id: string;
  type: 'function';
  function: { name: string; arguments: string };
}

export interface ProxyToolDefinition {
  type: 'function';
  function: {
    name: string;
    description: string;
    parameters: Record<string, unknown>;
  };
}

export interface RuntimeReasoningProfile {
  transport?: string;
  fallbackProfile?: string;
  levels?: string[];
  /**
   * Which level the Auto tier injects is specified authoritatively by the server; with no
   * declaration, Auto injects nothing. Injecting nothing means inheriting the upstream default,
   * which can be very slow: DeepSeek defaults to reasoning_effort=high, measured at roughly 93s of
   * thinking on a complex question as of 2026-08, which is what made "the user picked nothing and it
   * hangs" happen.
   */
  defaultLevel?: string;
  params?: Record<string, JSONObject>;
}

export interface RuntimeWebSearchProfile {
  mergeParams?: JSONObject;
  maxToolLoops?: number;
}

export interface RuntimeImageGenProfile {
  route?: string;
  streaming?: boolean;
  supportsContext?: boolean;
  mergeParams?: JSONObject;
  defaultParams?: JSONObject;
  requestDefaults?: JSONObject;
}

export interface RuntimeModelMetadata {
  canonicalModelId?: string;
  aliases?: string[];
  displayName?: string;
  contextLength?: number;
  maxOutputTokens?: number;
  supportsTemperature?: boolean;
  pricing?: {
    promptPerMToken: number;
    completionPerMToken: number;
    cachedInputPerMToken?: number | null;
  };
  capabilities?: string[];
  /** Model-level protocol kind, delivered by the backend as defaultTransport, e.g. "openai_responses" / "openai_chat".
   *  The request builder picks the endpoint from it: grok-4.20-multi-agent, for example, is barred from chat completions by xAI and must use Responses. */
  transport?: string;
  /** Automatic request controls the server already resolved by provider + transport + exact model. */
  capabilityControls?: RuntimeCapabilityModel['capabilityControls'];
  profiles?: {
    reasoning?: string | null;
    webSearch?: string | null;
    imageGen?: string | null;
    generation?: RuntimeGenerationProfileRef | null;
  };
  uiHints?: {
    groupKey?: string;
    groupName?: string;
    rank?: number;
    recommended?: boolean;
    badgeOrder?: string[];
  };
}

export interface RuntimeGenerationParameterDefinition {
  group?: string;
  valueSchema?: string;
  range?: Record<string, number>;
  enumValues?: Array<string | number>;
  fixedValue?: GenerationParameterValue;
  defaultDescription?: string | number;
  interactionGroup?: string;
  portability?: string;
  risk?: string;
  conflictsWith?: string[];
  requires?: Array<Record<string, unknown>>;
  constraints?: Array<Record<string, unknown>>;
}

export interface RuntimeGenerationTemplate {
  transport?: string;
  wire?: Record<string, string>;
}

export interface RuntimeGenerationProfileRef {
  template?: string;
  /** Opaque semantic profile revision; absent on legacy metadata. */
  revision?: string;
  /** Lean metadata points at the response-level parameter table. */
  parametersRef?: string;
  parameters?: Array<{
    id?: string;
    support?: string;
    source?: string;
  }>;
}

export interface RuntimeGenerationProfiles {
  version?: number;
  parameters?: Record<string, RuntimeGenerationParameterDefinition>;
  templates?: Record<string, RuntimeGenerationTemplate>;
}

export interface RuntimeProviderMetadata {
  displayName?: string;
  defaultModelId?: string;
  validation?: ProviderValidationContract;
  transport?: ProviderTransportDefinition;
  resolveMap?: Record<string, string>;
  models: Record<string, RuntimeModelMetadata>;
}

export interface RuntimeMetadataResponse {
  version: number;
  updatedAt: string;
  /** R4 lean view dictionary; absent from full metadata. */
  generationParameterTables?: Record<string, RuntimeGenerationProfileRef['parameters']>;
  profiles: {
    reasoning: Record<string, RuntimeReasoningProfile>;
    webSearch: Record<string, RuntimeWebSearchProfile>;
    imageGen: Record<string, RuntimeImageGenProfile>;
    generation?: RuntimeGenerationProfiles;
  };
  providers: Record<string, RuntimeProviderMetadata>;
  /**
   * Public provider configuration sent by the backend. The server side consumes only the protocol
   * parameters inside `protocolFeatures`, such as the endpoint and required headers for a Grok
   * subscription login. Those values must be resolved by the server from metadata; an arbitrary URL
   * passed in from the browser is never accepted, or the Next route becomes an open proxy.
   */
  providerConfigs?: Array<{
    kind: string;
    protocolFeatures?: Record<string, unknown> | null;
  }>;
  /** Authoritative recipe registry; invalid or unknown versions are ignored fail-safe by the execution compiler. */
  capabilityRuntime?: CapabilityRuntimeEnvelope;
  /** Relay runtime configuration, delivered in the same /metadata response; a direct desktop main-process relay reads the transport rule override and falls back to a heuristic when it is missing. */
  relayRuntimeConfig?: RelayRuntimeConfig;
}

export interface ResolvedRuntimeModel {
  provider: RuntimeProviderMetadata;
  model: RuntimeModelMetadata;
  canonicalModelId: string;
}

const SNAPSHOT_DATE_PATTERNS = [
  /-\d{8}$/,
  /-\d{4}-\d{2}-\d{2}$/,
];
const NON_AUTO_REASONING_MODES: ReasoningMode[] = ['fast', 'balanced', 'deep', 'max'];
const REASONING_MODE_ORDER: ReasoningMode[] = ['automatic', ...NON_AUTO_REASONING_MODES];

export function resolveRuntimeModel(
  metadata: RuntimeMetadataResponse | null,
  providerKind: ProviderKind,
  modelID: string,
): ResolvedRuntimeModel | null {
  if (!metadata) return null;

  const provider = metadata.providers[providerKind];
  if (!provider?.resolveMap) return null;

  const canonicalModelId = lookupCandidates(modelID)
    .map((candidate) => provider.resolveMap?.[candidate] ?? (provider.models[candidate] ? candidate : null))
    .find((candidate): candidate is string => Boolean(candidate));
  if (!canonicalModelId) return null;

  const model = provider.models[canonicalModelId];
  if (!model) return null;

  return {
    provider,
    model,
    canonicalModelId: model.canonicalModelId ?? canonicalModelId,
  };
}

function lookupCandidates(modelID: string): string[] {
  const trimmed = modelID.trim();
  if (!trimmed) return [];

  const normalized = SNAPSHOT_DATE_PATTERNS.reduce(
    (current, pattern) => current.replace(pattern, ''),
    trimmed,
  );

  return normalized === trimmed ? [trimmed] : [trimmed, normalized];
}

export function resolveReasoningParams(
  metadata: RuntimeMetadataResponse | null,
  profileName: string | null | undefined,
  reasoningMode: ReasoningMode | undefined,
): JSONObject | null {
  const normalizedMode = normalizeReasoningMode(metadata, profileName, reasoningMode);
  if (!metadata || !profileName || !normalizedMode) return null;
  const profile = metadata.profiles.reasoning[profileName];
  if (!profile?.params) return null;
  // Auto tier: inject a level only when the profile declares defaultLevel explicitly, otherwise
  // inject nothing. The level value is still looked up only in params[level]; the client does no
  // local mapping of its own.
  const effectiveLevel =
    normalizedMode === 'automatic' ? profile.defaultLevel : normalizedMode;
  if (!effectiveLevel) return null;
  return profile.params[effectiveLevel] ?? null;
}

export function resolveReasoningProfile(
  metadata: RuntimeMetadataResponse | null,
  profileName: string | null | undefined,
): RuntimeReasoningProfile | null {
  if (!metadata || !profileName) return null;
  return metadata.profiles.reasoning[profileName] ?? null;
}

/**
 * Display surface for the levels. It must agree with the injection surface
 * ({@link resolveReasoningParams}): when the injection surface finds no profile it returns null and
 * injects nothing, so a display surface that still offered all five levels would show five purely
 * decorative levels backed by zero injection.
 */
export function resolveSupportedReasoningModes(
  metadata: RuntimeMetadataResponse | null,
  profileName: string | null | undefined,
): ReasoningMode[] {
  // A missing profileName means the catalog gave this model no reasoning profile at all, which is
  // the normal case for relay: the backend metadata has no relay key, so resolveRuntimeModel always
  // returns null and the levels fall back to buildRelayReasoningParams mapping them locally at
  // dispatch time (relay is the one sanctioned exception). Narrowing here as well would let
  // normalizeReasoningMode clamp the user's choice to automatic and relay would lose
  // reasoning_effort entirely. Only official providers are tightened; this branch stays fail-open.
  if (!metadata || !profileName) {
    return REASONING_MODE_ORDER;
  }

  // A profile name that is not in the profile table (the server withdrew it, or the client holds an
  // old snapshot), or a profile that declares no levels: the injection surface returns null here, so
  // the display surface has to collapse to Auto only.
  const levels = metadata.profiles.reasoning[profileName]?.levels;
  if (!levels || levels.length === 0) {
    return ['automatic'];
  }

  const normalized = NON_AUTO_REASONING_MODES.filter((mode) => levels.includes(mode));
  if (normalized.length === 0) {
    return ['automatic'];
  }

  return ['automatic', ...normalized];
}

export function normalizeReasoningMode(
  metadata: RuntimeMetadataResponse | null,
  profileName: string | null | undefined,
  reasoningMode: ReasoningMode | undefined,
): ReasoningMode | undefined {
  if (!reasoningMode) return reasoningMode;

  const supportedModes = resolveSupportedReasoningModes(metadata, profileName);
  if (supportedModes.includes(reasoningMode)) {
    return reasoningMode;
  }

  const modeIndex = REASONING_MODE_ORDER.indexOf(reasoningMode);
  for (let index = modeIndex - 1; index >= 0; index -= 1) {
    const candidate = REASONING_MODE_ORDER[index];
    if (supportedModes.includes(candidate)) {
      return candidate;
    }
  }

  return 'automatic';
}

export function resolveImageGenProfile(
  metadata: RuntimeMetadataResponse | null,
  profileName: string | null | undefined,
): RuntimeImageGenProfile | null {
  if (!metadata || !profileName) return null;
  return metadata.profiles.imageGen[profileName] ?? null;
}

export function resolveWebSearchProfile(
  metadata: RuntimeMetadataResponse | null,
  profileName: string | null | undefined,
): RuntimeWebSearchProfile | null {
  if (!metadata || !profileName) return null;
  return metadata.profiles.webSearch[profileName] ?? null;
}

/**
 * Only templates and canonical parameter references sent by the server are accepted; an unknown
 * reference keeps its original value but is not auto-enabled, so a new enum cannot degrade the whole
 * metadata or request path.
 */
export function resolveGenerationProfile(
  metadata: RuntimeMetadataResponse | null,
  ref: RuntimeGenerationProfileRef | null | undefined,
): GenerationParameterProfile | undefined {
  const templateName = ref?.template;
  if (!metadata || !templateName) return undefined;
  const generation = metadata.profiles.generation;
  const template = generation?.templates?.[templateName];
  if (!template?.wire) return undefined;
  const parameters = ref?.parametersRef !== undefined
    ? metadata.generationParameterTables?.[ref.parametersRef]
    : ref?.parameters;

  return {
    template: templateName,
    ...(typeof ref?.revision === 'string' && ref.revision ? { revision: ref.revision } : {}),
    wire: { ...template.wire },
    parameters: (parameters ?? [])
      .flatMap((entry) => {
        const id = entry.id;
        if (!id) return [];
        const definition = generation?.parameters?.[id];
          return [{
          id,
          support: entry.support ?? 'unknown',
          source: entry.source ?? 'unknown',
            conflictsWith: definition?.conflictsWith,
           group: definition?.group,
           valueSchema: definition?.valueSchema,
           range: definition?.range,
           enumValues: definition?.enumValues,
           fixedValue: definition?.fixedValue,
           defaultDescription: definition?.defaultDescription,
           interactionGroup: definition?.interactionGroup,
           requires: definition?.requires,
           constraints: definition?.constraints,
           portability: definition?.portability,
           risk: definition?.risk,
          }];
      }),
  };
}

export function deepMerge<T extends JSONObject>(target: T, source: JSONObject | null | undefined): T {
  if (!source) return target;

  const targetObject = target as JSONObject;

  for (const [key, value] of Object.entries(source)) {
    if (isPlainObject(value) && isPlainObject(targetObject[key])) {
      deepMerge(targetObject[key] as JSONObject, value as JSONObject);
      continue;
    }

    if (Array.isArray(value)) {
      targetObject[key] = key === 'tools' || key === 'plugins'
        ? composeOwnedArray(targetObject[key], value)
        : [...value];
      continue;
    }

    targetObject[key] = value;
  }

  return target;
}

/** Patches may contribute tools/plugins, never erase the builder's base entries. */
function composeOwnedArray(base: unknown, contribution: readonly unknown[]): unknown[] {
  const out = Array.isArray(base) ? [...base] : [];
  const identities = new Set(out.map(ownedArrayIdentity));
  for (const item of contribution) {
    const identity = ownedArrayIdentity(item);
    if (identities.has(identity)) continue;
    identities.add(identity);
    out.push(item);
  }
  return out;
}

function ownedArrayIdentity(value: unknown): string {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    const record = value as Record<string, unknown>;
    const type = typeof record.type === 'string' ? record.type : '';
    const name = typeof record.name === 'string' ? record.name : '';
    return `${type}:${name || stableJson(record)}`;
  }
  return JSON.stringify(value);
}
function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') {
    const record = value as Record<string, unknown>;
    const entries = Object.keys(record)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stableJson(record[key])}`);
    return `{${entries.join(',')}}`;
  }
  return JSON.stringify(value);
}

export function usesOfficialOpenAIAPI(baseURL?: string): boolean {
  return resolveProviderBaseURL('openAI', baseURL) === providerDefaults.openAI.defaultBaseURL;
}

export function buildOpenAIChatMessages(messages: ProxyMessage[]) {
  return messages.map((message) => ({
    role: message.role,
    content: typeof message.content === 'string'
      ? message.content
      : message.content.map((part) => {
        if (part.type === 'text') {
          return { type: 'text' as const, text: part.text };
        }
        if (part.type === 'image_url') {
          return { type: 'image_url' as const, image_url: { url: part.image_url.url } };
        }
        if (part.type === 'video_url') {
          return { type: 'video_url' as const, video_url: { url: part.video_url.url } };
        }
        return { type: 'image_url' as const, image_url: { url: part.file.file_data } };
      }),
    ...(message.role === 'assistant' && message.tool_calls
      ? { tool_calls: message.tool_calls }
      : {}),
    ...(message.role === 'tool' && message.tool_call_id
      ? { tool_call_id: message.tool_call_id }
      : {}),
  }));
}

export function buildDashScopeMessages(messages: ProxyMessage[]) {
  return messages.map((message) => ({
    role: message.role,
    content: typeof message.content === 'string'
      ? message.content
      : message.content.map((part) => {
        if (part.type === 'text') return part.text;
        if (part.type === 'image_url') return `[image: ${part.image_url.url}]`;
        if (part.type === 'video_url') return `[video: ${part.video_url.url}]`;
        return `[file: ${part.file.filename}]`;
      }).join('\n'),
  }));
}

export function buildOpenAIResponsesInput(messages: ProxyMessage[]) {
  return messages.map((message) => ({
    role: message.role,
    content: buildResponsesContent(message.content, message.role),
  }));
}

export function buildAnthropicRequestPayload(messages: ProxyMessage[]) {
  const systemTexts: string[] = [];

  const anthropicMessages = messages
    .filter((message) => {
      if (message.role === 'system') {
        const systemText = typeof message.content === 'string'
          ? message.content
          : extractTextContent(message.content);
        if (systemText.trim()) {
          systemTexts.push(systemText.trim());
        }
        return false;
      }
      return true;
    })
    .map((message) => ({
      role: message.role as 'user' | 'assistant',
      content: typeof message.content === 'string'
        ? message.content
        : message.content.map((part) => {
          if (part.type === 'text') {
            return { type: 'text' as const, text: part.text };
          }

          if (part.type === 'image_url') {
            const data = parseDataURL(part.image_url.url);
            if (data) {
              return {
                type: 'image' as const,
                source: { type: 'base64' as const, media_type: data.mimeType, data: data.base64 },
              };
            }
            return { type: 'text' as const, text: `[image: ${part.image_url.url}]` };
          }

          if (part.type === 'video_url') {
            return { type: 'text' as const, text: `[video: ${part.video_url.url}]` };
          }

          const data = parseDataURL(part.file.file_data);
          if (data) {
            return {
              type: 'document' as const,
              source: { type: 'base64' as const, media_type: data.mimeType, data: data.base64 },
            };
          }
          return { type: 'text' as const, text: `[file: ${part.file.filename}]` };
        }),
    }));

  const systemText = systemTexts.length > 0 ? systemTexts.join('\n\n') : undefined;
  return { systemText, messages: anthropicMessages };
}

export function buildGeminiContents(messages: ProxyMessage[]) {
  return messages
    .filter((message) => message.role !== 'system')
    .map((message) => ({
      role: message.role === 'assistant' ? 'model' : 'user',
      parts: typeof message.content === 'string'
        ? [{ text: message.content }]
        : message.content.map((part) => {
          if (part.type === 'text') {
            return { text: part.text };
          }

          if (part.type === 'image_url') {
            const data = parseDataURL(part.image_url.url);
            if (data) {
              return { inlineData: { mimeType: data.mimeType, data: data.base64 } };
            }
            return { text: `[image: ${part.image_url.url}]` };
          }

          if (part.type === 'video_url') {
            const data = parseDataURL(part.video_url.url);
            if (data) {
              return { inlineData: { mimeType: data.mimeType, data: data.base64 } };
            }
            return { text: `[video: ${part.video_url.url}]` };
          }

          const data = parseDataURL(part.file.file_data);
          if (data) {
            return { inlineData: { mimeType: data.mimeType, data: data.base64 } };
          }
          return { text: `[file: ${part.file.filename}]` };
        }),
    }));
}

export function buildGeminiRequestPayload(messages: ProxyMessage[]) {
  const systemTexts = messages
    .filter((message) => message.role === 'system')
    .map((message) => typeof message.content === 'string'
      ? message.content
      : extractTextContent(message.content))
    .map((text) => text.trim())
    .filter(Boolean);

  return {
    contents: buildGeminiContents(messages),
    systemInstruction: systemTexts.length > 0
      ? { parts: [{ text: systemTexts.join('\n\n') }] }
      : undefined,
  };
}

function buildResponsesContent(
  content: string | ContentPart[],
  role: ProxyMessage['role'],
) {
  const textType = role === 'assistant' ? 'output_text' : 'input_text';
  if (typeof content === 'string') {
    return [{ type: textType, text: content }];
  }

  const textParts: string[] = [];
  const imageParts: string[] = [];
  const videoParts: string[] = [];
  const fileParts: Array<{ filename: string; file_data: string }> = [];

  for (const part of content) {
    if (part.type === 'text') {
      textParts.push(part.text);
      continue;
    }

    if (part.type === 'image_url') {
      imageParts.push(part.image_url.url);
      continue;
    }

    if (part.type === 'video_url') {
      videoParts.push(part.video_url.url);
      continue;
    }

    fileParts.push({
      filename: part.file.filename,
      file_data: part.file.file_data,
    });
  }

  if (imageParts.length === 0 && videoParts.length === 0 && fileParts.length === 0) {
    return textParts.join('\n\n');
  }

  const parts: Array<{
    type: string;
    text?: string;
    image_url?: string;
    video_url?: string;
    filename?: string;
    file_data?: string;
  }> = [];

  const combinedText = textParts.join('\n\n').trim();
  if (combinedText) {
    parts.push({ type: textType, text: combinedText });
  }

  for (const imageURL of imageParts) {
    parts.push({ type: 'input_image', image_url: imageURL });
  }

  for (const videoURL of videoParts) {
    parts.push({ type: 'input_video', video_url: videoURL });
  }

  for (const file of fileParts) {
    parts.push({
      type: 'input_file',
      filename: file.filename,
      file_data: file.file_data,
    });
  }

  return parts;
}

function extractTextContent(parts: ContentPart[]): string {
  return parts
    .filter((part) => part.type === 'text')
    .map((part) => part.text)
    .join('\n');
}

function parseDataURL(value: string): { mimeType: string; base64: string } | null {
  const match = value.match(/^data:([^;]+);base64,(.+)$/);
  if (!match) return null;
  return {
    mimeType: match[1],
    base64: match[2],
  };
}

function isPlainObject(value: unknown): value is JSONObject {
  return value != null && typeof value === 'object' && !Array.isArray(value);
}
