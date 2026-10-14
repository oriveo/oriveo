/**
 * The protocol of an official provider is decided by metadata `providerConfigs[].apiProtocol`.
 *
 * Each provider has one native protocol family; a delivered value equal to the native family, missing or unknown -> returns null and the caller uses today's per-provider
 * builder (the request is byte-for-byte unchanged, guarded by golden tests). A delivered value of another known protocol -> use the Relay per-protocol builders
 * (body / endpoint share the same code as relay-orchestrator); providerKind only decides auth and extra headers;
 * dialect differences in the per-provider builders are not carried over.
 */
import type { ProviderKind } from '@oriveo/shared/pure-types';
import { normalizeRelayBaseURL } from '../relay-endpoints';
import { resolveRelayTransportRule } from '../relay-runtime-support';
import {
  buildRelayAnthropicMessagesBody,
  buildRelayChatCompletionsBody,
  buildRelayGeminiGenerateContentBody,
  buildRelayResponsesBody,
  relayProtocolUpstreamURL,
  type RelayMessages,
} from '../relay-orchestrator';
import type { RelayRuntimeConfig } from '../../ports';
import type { StreamOptions } from '../types';
import { resolveProviderBaseURL } from '../url-utils';
import { credentialHeader } from './generation-parameters';
import { STREAM_HEADERS, type ProviderRequest, type RequestParams } from './types';

export type OfficialProtocol =
  | 'openai_chat_completions'
  | 'openai_responses'
  | 'anthropic_messages'
  | 'gemini_generate_content';

type ProtocolFamily = 'openai' | 'anthropic' | 'gemini';

/** Delivered vocabulary -> protocol. Unknown values return undefined (treated as native). */
function protocolForAPIValue(value: string): OfficialProtocol | undefined {
  switch (value) {
    case 'openai':
    case 'openai_compatible':
    case 'openai_chat_completions':
      return 'openai_chat_completions';
    case 'openai_responses':
      return 'openai_responses';
    case 'anthropic':
    case 'anthropic_messages':
      return 'anthropic_messages';
    case 'gemini':
    case 'gemini_generate_content':
      return 'gemini_generate_content';
    default:
      return undefined;
  }
}

function nativeFamily(providerKind: ProviderKind | string): ProtocolFamily | undefined {
  switch (providerKind) {
    case 'anthropic':
      return 'anthropic';
    case 'gemini':
      return 'gemini';
    case 'relay':
      return undefined;
    default:
      return 'openai';
  }
}

function familyOf(protocol: OfficialProtocol): ProtocolFamily {
  switch (protocol) {
    case 'anthropic_messages':
      return 'anthropic';
    case 'gemini_generate_content':
      return 'gemini';
    // The per-provider builder of the openai native family picks Chat / Responses by the model's transport itself; no rerouting within the family.
    case 'openai_chat_completions':
      return 'openai';
    case 'openai_responses':
      return 'openai';
  }
}

/** Whether this provider switches to a non-native protocol; null = use the per-provider builder. */
export function officialAlternateProtocol(
  providerKind: ProviderKind | string,
  apiProtocol: string | null | undefined,
): OfficialProtocol | null {
  const native = nativeFamily(providerKind);
  if (!native || typeof apiProtocol !== 'string') return null;
  const protocol = protocolForAPIValue(apiProtocol.trim().toLowerCase());
  if (!protocol) return null;
  // For the openai family a delivered openai_responses counts as another protocol; for the others, the same family is native.
  if (protocol === 'openai_responses' && native === 'openai') return protocol;
  return familyOf(protocol) === native ? null : protocol;
}

/** The auth scheme is decided only by providerKind (the same credential headers as each native builder). */
function providerAuthHeaders(providerKind: ProviderKind | string, apiKey: string): Record<string, string> {
  switch (providerKind) {
    case 'anthropic':
      return credentialHeader('x-api-key', apiKey);
    case 'gemini':
      return credentialHeader('x-goog-api-key', apiKey);
    default: {
      const credential = apiKey.trim();
      return credential ? { Authorization: `Bearer ${credential}` } : {};
    }
  }
}

/** Extra headers required by the protocol itself (excluding credentials). */
function protocolHeaders(protocol: OfficialProtocol): Record<string, string> {
  return protocol === 'anthropic_messages' ? { 'anthropic-version': '2023-06-01' } : {};
}

export function buildOfficialAlternateProtocolRequest(
  params: RequestParams,
  protocol: OfficialProtocol,
  /** Base URL delivered for this provider (already checked against the trusted table); when missing use the user's address, then the built-in default. */
  trustedMetadataBaseURL: string | undefined,
  runtimeConfig: RelayRuntimeConfig | null,
): ProviderRequest {
  const base = trustedMetadataBaseURL
    ?? resolveProviderBaseURL(params.providerKind, params.baseURL);
  const apiRoot = normalizeRelayBaseURL(base, protocol);
  // Generation parameters are written only when the profile template is exactly this protocol; a template mismatch means zero injection (same as the existing dispatch behavior).
  const generationProfile = params.options?.generationProfile?.template === protocol
    ? params.options.generationProfile
    : undefined;
  const options: StreamOptions = {
    relayStream: params.stream !== false,
    ...(params.options?.reasoning !== undefined ? { reasoning: params.options.reasoning } : {}),
    ...(params.options?.supportsWebSearch !== undefined ? { supportsWebSearch: params.options.supportsWebSearch } : {}),
    ...(generationProfile ? { generationProfile, generationParameters: params.options?.generationParameters } : {}),
  };
  // The local tool leg (tool role) is not expressed in the Relay builders of these protocols, so it is not carried over.
  const messages = params.messages.filter((message) => message.role !== 'tool') as RelayMessages;
  const body = protocol === 'anthropic_messages'
    ? buildRelayAnthropicMessagesBody(params.modelID, messages, options)
    : protocol === 'gemini_generate_content'
      ? buildRelayGeminiGenerateContentBody(messages, options)
      : protocol === 'openai_responses'
        ? buildRelayResponsesBody(params.modelID, messages, options, runtimeConfig).body
        : buildRelayChatCompletionsBody(params.modelID, messages, options).body;
  appendOfficialWebSearchTool(body, protocol, options, runtimeConfig);
  return {
    url: relayProtocolUpstreamURL(apiRoot, params.modelID, protocol, options),
    headers: {
      ...STREAM_HEADERS,
      ...providerAuthHeaders(params.providerKind, params.apiKey),
      ...protocolHeaders(protocol),
    },
    body,
  };
}

/**
 * Web-search tool added per the web-search preference when an official provider switches to a non-native protocol (identical to the wording formerly in the Relay builder).
 * After relay web search became connection-level fragments, this belongs only to the official path, so it was moved here from the shared builder.
 */
function appendOfficialWebSearchTool(
  body: Record<string, unknown>,
  protocol: OfficialProtocol,
  options: StreamOptions,
  runtimeConfig: RelayRuntimeConfig | null,
): void {
  if (!options.supportsWebSearch) return;
  if (protocol === 'openai_responses') {
    const toolName = (runtimeConfig
      ? resolveRelayTransportRule('openai_responses', runtimeConfig)?.webSearchToolName
      : undefined) ?? 'web_search';
    if (toolName !== 'disabled' && Array.isArray(body.tools)) body.tools.push({ type: toolName });
  } else if (protocol === 'gemini_generate_content') {
    body.tools = [{ googleSearch: {} }];
  }
}
