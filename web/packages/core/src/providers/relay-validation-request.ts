import type { RelayRequestedConfig } from '@oriveo/shared/pure-types';
import {
  buildDirectAuthHeaders,
  buildRelayProtocolHeaders,
  type RelayDirectFetchConfig,
} from './relay-adapter';
import { buildRelayEndpointURL, type RelayEndpointTransport } from './relay-endpoints';
import { networkError } from './errors';

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
  /** `baseURL` is already a resolved API root (the per-model probe's effectiveAPIRoot): use it as is, without appending a version segment. */
  exactBaseURL?: boolean;
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
 * The URL / auth / protocol headers / custom transport configuration of one relay generation request (the parts unrelated to the body).
 * The 1-token validation and the user-triggered "test capability" share this one copy and differ only in the body.
 */
export function buildRelayGenerationEnvelope(
  input: RelayGenerationValidationConfig,
): Pick<RelayGenerationValidationRequest, 'method' | 'upstreamURL' | 'directConfig' | 'baseHeaders' | 'probedEndpoint'> {
  const modelID = requireModelID(input.modelID);
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
  const endpointURL = (endpoint: Parameters<typeof buildRelayEndpointURL>[0]['endpoint']) => buildRelayEndpointURL({
    baseURL: input.baseURL,
    transport: input.transport,
    endpoint,
    ...(endpoint === 'geminiGenerateContent' ? { modelID } : {}),
    securityMode: input.securityMode,
    exactBaseURL: input.exactBaseURL,
  });

  switch (input.transport) {
    case 'openai_responses':
      return { method: 'POST', upstreamURL: endpointURL('responses'), directConfig, baseHeaders, probedEndpoint: 'POST /responses' };
    case 'anthropic_messages':
      return { method: 'POST', upstreamURL: endpointURL('messages'), directConfig, baseHeaders, probedEndpoint: 'POST /v1/messages' };
    case 'gemini_generate_content':
      return { method: 'POST', upstreamURL: endpointURL('geminiGenerateContent'), directConfig, baseHeaders, probedEndpoint: 'POST :generateContent' };
    case 'llamacpp_native':
    case 'openai_chat_completions':
      return { method: 'POST', upstreamURL: endpointURL('chatCompletions'), directConfig, baseHeaders, probedEndpoint: 'POST /chat/completions' };
  }
}

/**
 * The 1-token generation request builder for explicit relay validation (pure logic).
 * On Web the probes for the four chat protocols are now produced by the chat request builders (see app `buildRelayPingRequest`);
 * in production only the llama.cpp native protocol still goes through here, so the type accepts only it. The output cap and prompt are shared as the constants below.
 */
export function buildRelayGenerationValidationRequest(
  input: RelayGenerationValidationConfig & { transport: 'llamacpp_native' },
): RelayGenerationValidationRequest {
  const modelID = requireModelID(input.modelID);
  const envelope = buildRelayGenerationEnvelope(input);
  return { ...envelope, body: validationBody(modelID) };
}

/** No request is sent without a validation sample: a hard-coded model name is never used to hit the upstream on the user's behalf. */
function requireModelID(value: string): string {
  const modelID = value.trim();
  if (!modelID) throw networkError('No model to verify this relay with.');
  return modelID;
}

/** The one-line probe conversation and output cap (fixture `probe-orchestration.v1.json` probeRequestRules). */
export const RELAY_PROBE_PROMPT = 'ping';
/** Responses uses the official minimum of 16 for the output cap; 1 is rejected by the upstream as an invalid parameter. */
export const RELAY_PROBE_RESPONSES_MAX_OUTPUT_TOKENS = 16;
export const RELAY_PROBE_MAX_TOKENS = 1;

const VALIDATION_PROMPT = RELAY_PROBE_PROMPT;

function validationBody(modelID: string): Record<string, unknown> {
  return { model: modelID, stream: false, max_tokens: RELAY_PROBE_MAX_TOKENS, messages: [{ role: 'user', content: VALIDATION_PROMPT }] };
}
