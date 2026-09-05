import type { RelayRequestedConfig } from '@oriveo/shared/pure-types';
import { buildDirectAuthHeaders, buildRelayProtocolHeaders, type RelayDirectFetchConfig } from './relay-adapter';
import { buildRelayEndpointURL, type RelayEndpointTransport } from './relay-endpoints';

/**
 * Relay configuration for one explicit connection validation, with auto already resolved.
 * The object can be passed straight over IPC and contains no functions or runtime objects.
 */
export interface RelayGenerationValidationConfig {
  baseURL: string;
  apiKey: string;
  modelID: string;
  transport: RelayEndpointTransport;
  authMode: Exclude<RelayRequestedConfig['authMode'], 'auto'>;
  securityMode?: RelayRequestedConfig['securityMode'];
  codexCompatIdentity?: boolean;
  customUserAgent?: string;
  headers?: RelayRequestedConfig['headers'];
  queryParams?: RelayRequestedConfig['queryParams'];
  disableResponseStorage?: boolean;
}

export interface RelayGenerationValidationRequest {
  method: 'POST';
  upstreamURL: string;
  body: Record<string, unknown>;
  /** Resolved auth, protocol headers and custom transport configuration, so each host can send it with its own I/O. */
  directConfig: RelayDirectFetchConfig;
  baseHeaders: Record<string, string>;
  probedEndpoint: string;
}

/**
 * The single 1-token generation request builder for explicit relay validation.
 * Pure logic only: every host must use this output rather than switching on endpoint/body/header itself.
 */
export function buildRelayGenerationValidationRequest(
  input: RelayGenerationValidationConfig,
): RelayGenerationValidationRequest {
  const modelID = input.modelID.trim() || 'gpt-4o';
  const directConfig: RelayDirectFetchConfig = {
    apiKey: input.apiKey,
    transport: input.transport,
    authMode: input.authMode,
    method: 'POST',
    codexCompatIdentity: input.codexCompatIdentity,
    customUserAgent: input.customUserAgent,
    headers: input.headers,
    queryParams: input.queryParams,
    securityMode: input.securityMode,
  };
  const baseHeaders = {
    'Content-Type': 'application/json',
    ...buildDirectAuthHeaders(input.apiKey, input.authMode),
    ...buildRelayProtocolHeaders(input.transport),
  };

  switch (input.transport) {
    case 'openai_responses':
      return {
        method: 'POST',
        upstreamURL: buildRelayEndpointURL({ baseURL: input.baseURL, transport: input.transport, endpoint: 'responses', securityMode: input.securityMode }),
        body: {
          model: modelID,
          input: [{ role: 'user', content: [{ type: 'input_text', text: 'ping' }] }],
          max_output_tokens: 1,
          stream: false,
          ...(input.disableResponseStorage ? { store: false } : {}),
        },
        directConfig,
        baseHeaders,
        probedEndpoint: 'POST /responses',
      };
    case 'anthropic_messages':
      return {
        method: 'POST',
        upstreamURL: buildRelayEndpointURL({ baseURL: input.baseURL, transport: input.transport, endpoint: 'messages', securityMode: input.securityMode }),
        body: { model: modelID, max_tokens: 1, messages: [{ role: 'user', content: 'ping' }] },
        directConfig,
        baseHeaders,
        probedEndpoint: 'POST /v1/messages',
      };
    case 'gemini_generate_content':
      return {
        method: 'POST',
        upstreamURL: buildRelayEndpointURL({ baseURL: input.baseURL, transport: input.transport, endpoint: 'geminiGenerateContent', modelID, securityMode: input.securityMode }),
        body: { contents: [{ role: 'user', parts: [{ text: 'ping' }] }], generationConfig: { maxOutputTokens: 1 } },
        directConfig,
        baseHeaders,
        probedEndpoint: 'POST :generateContent',
      };
    case 'llamacpp_native':
    case 'openai_chat_completions':
      return {
        method: 'POST',
        upstreamURL: buildRelayEndpointURL({ baseURL: input.baseURL, transport: input.transport, endpoint: 'chatCompletions', securityMode: input.securityMode }),
        body: { model: modelID, stream: false, max_tokens: 1, messages: [{ role: 'user', content: 'ping' }] },
        directConfig,
        baseHeaders,
        probedEndpoint: 'POST /chat/completions',
      };
  }
}
