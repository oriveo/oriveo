/**
 * Chat attachment line declarations: how each **actual outbound line** takes files, declared once here.
 *
 * Whether a file goes out as a native upload or as injected text cannot be decided from the model allowlist
 * alone. One provider has several lines, and a line whose request format has no native file block only
 * loses a `file` part it receives (treats it as an image, writes a file-name placeholder, or puts the
 * base64 into the body). The delivery decision therefore takes "line + model".
 *
 * Adding a line: after adding an entry to `ATTACHMENT_TRANSPORTS`, the `PROFILES` below (`satisfies Record`)
 * and the probe table in the contrast test both fail to type-check until the declaration is filled in.
 */
import type { ProviderKind } from '@oriveo/shared/pure-types';
import type { ProviderRequest } from './request-builders/types';
import type { ContentPart } from './types';

export const ATTACHMENT_TRANSPORTS = [
  'openai_chat',
  'openai_responses',
  'openai_subscription_codex',
  'anthropic_messages',
  'gemini_generate',
  'gemini_interactions',
  'openrouter_chat',
  'grok_chat',
  'grok_responses',
  'grok_subscription_chat',
  'grok_subscription_responses',
  'minimax_chat',
  'minimax_anthropic_messages',
  'deepseek_chat',
  'qwen_chat',
  'moonshot_chat',
  'moonshot_browser_direct',
  'zhipu_chat',
  'siliconflow_chat',
  'openai_compatible_chat',
  'relay_openai_chat',
  'relay_openai_responses',
  'relay_anthropic_messages',
  'relay_gemini_generate',
  'relay_llamacpp_native',
] as const;

export type AttachmentTransport = (typeof ATTACHMENT_TRANSPORTS)[number];

/** The native block a `file` part becomes in the request format; `null` = this line's request format has no native file block. */
export type NativeFileBlock = 'input_file' | 'document' | 'inline_data' | 'file';

/**
 * Three levels of native file support:
 * - `always`: go native according to the model allowlist and routing rules; an upstream rejection is a
 *   failure (lines verified against the real provider).
 * - `alwaysWithTextFallback`: routes exactly like `always`. The difference is after a rejection: when the
 *   upstream answers 400 / 404 / 413 / 415 / 422 before producing any output, native files that have
 *   extracted text are switched to text injection and the request is resent once; after a success this
 *   connection stops sending file blocks for the rest of the page session. For relays and subscription
 *   backends, which differ in whether they pass file blocks through.
 * - `off`: always inject as text.
 */
export type NativeFileMode = 'always' | 'alwaysWithTextFallback' | 'off';

/** Upstream status codes that trigger the text fallback: the ones where the request itself is not accepted. Auth, rate limit, 5xx and network errors are not included. */
export const NATIVE_FILE_FALLBACK_STATUSES: ReadonlySet<number> = new Set([400, 404, 413, 415, 422]);

export type AttachmentWrapperVersion = 'xml-v1' | 'markdown-v1';

interface ProfileBase {
  /** Wrapper format when injecting as text. */
  wrapper: AttachmentWrapperVersion;
  /** Per-file cap on raw bytes for native upload. */
  maxNativeBytes: number;
  /** The native block a `file` part becomes on a leg with client tools (MCP / library agent); `null` = that leg carries text only. */
  toolLoopNativeFileBlock: NativeFileBlock | null;
  /** Placeholder text standing in for each image when this line can only send plain text. */
  imagePlaceholderText?: string;
}

/** A line without a native file block can only be `off`: otherwise a file routed to native would reach neither the body nor the request. */
export type AttachmentTransportProfile = ProfileBase & (
  | { nativeFileBlock: null; nativeFiles: 'off' }
  | { nativeFileBlock: NativeFileBlock; nativeFiles: NativeFileMode }
);

const MB = 1024 * 1024;
const DEFAULT_NATIVE_BYTES = 32 * MB;
/** Upstream cap for Gemini inlineData. */
const GEMINI_NATIVE_BYTES = 20 * MB;

/**
 * Placeholder written into the body for each image on a line that can only send plain text (the same literal
 * on every client): lets the model know the user attached an image that did not arrive. A line that already
 * has its own placeholder (DeepSeek) keeps it.
 */
export const TEXT_ONLY_ROUTE_IMAGE_PLACEHOLDER = '[Image omitted: this route sends text only]';

function textOnly(wrapper: AttachmentWrapperVersion, imagePlaceholderText?: string): AttachmentTransportProfile {
  return {
    nativeFileBlock: null,
    nativeFiles: 'off',
    wrapper,
    maxNativeBytes: DEFAULT_NATIVE_BYTES,
    toolLoopNativeFileBlock: null,
    ...(imagePlaceholderText ? { imagePlaceholderText } : {}),
  };
}

const PROFILES = {
  // -- Direct to the official API --
  openai_chat: textOnly('xml-v1'),
  openai_responses: {
    nativeFileBlock: 'input_file',
    nativeFiles: 'always',
    wrapper: 'xml-v1', maxNativeBytes: DEFAULT_NATIVE_BYTES, toolLoopNativeFileBlock: null,
  },
  anthropic_messages: {
    nativeFileBlock: 'document',
    nativeFiles: 'always',
    wrapper: 'xml-v1', maxNativeBytes: DEFAULT_NATIVE_BYTES, toolLoopNativeFileBlock: null,
  },
  gemini_generate: {
    nativeFileBlock: 'inline_data',
    nativeFiles: 'always',
    wrapper: 'xml-v1', maxNativeBytes: GEMINI_NATIVE_BYTES, toolLoopNativeFileBlock: null,
  },
  // The builder reuses generateContent parts, but on this line files arrive as text (the same on every client).
  gemini_interactions: {
    nativeFileBlock: 'inline_data',
    nativeFiles: 'off',
    wrapper: 'xml-v1', maxNativeBytes: GEMINI_NATIVE_BYTES, toolLoopNativeFileBlock: null,
  },
  // The tool leg is Chat Completions as well; turning on tools does not downgrade files to text.
  openrouter_chat: {
    nativeFileBlock: 'file',
    nativeFiles: 'always',
    wrapper: 'xml-v1', maxNativeBytes: DEFAULT_NATIVE_BYTES, toolLoopNativeFileBlock: 'file',
  },
  grok_chat: textOnly('xml-v1'),
  // The builder reuses the Responses input, but the Grok API-key line does not accept documents.
  grok_responses: {
    nativeFileBlock: 'input_file',
    nativeFiles: 'off',
    wrapper: 'xml-v1', maxNativeBytes: DEFAULT_NATIVE_BYTES, toolLoopNativeFileBlock: null,
  },
  minimax_chat: textOnly('markdown-v1'),
  // The builder reuses the Anthropic Messages content, but MiniMax does not accept documents.
  minimax_anthropic_messages: {
    nativeFileBlock: 'document',
    nativeFiles: 'off',
    wrapper: 'markdown-v1', maxNativeBytes: DEFAULT_NATIVE_BYTES, toolLoopNativeFileBlock: null,
  },
  // content takes a string only; the image placeholder is written by the builder (`buildDeepSeekMessages`).
  deepseek_chat: textOnly('markdown-v1', '[Image omitted: unsupported by DeepSeek]'),
  qwen_chat: textOnly('markdown-v1'),
  moonshot_chat: textOnly('markdown-v1'),
  // api.moonshot.cn is called directly from the browser (not through /api/chat/stream).
  moonshot_browser_direct: textOnly('markdown-v1'),
  zhipu_chat: textOnly('markdown-v1'),
  siliconflow_chat: textOnly('markdown-v1'),
  // Mistral / Groq / Together / Fireworks.
  openai_compatible_chat: textOnly('xml-v1'),

  // -- Subscription lines: not verified against the real provider, fall back to text when rejected --
  // Not verified against the real provider: whether the Codex backend reads input_file is unknown.
  openai_subscription_codex: {
    nativeFileBlock: 'input_file',
    nativeFiles: 'alwaysWithTextFallback',
    wrapper: 'xml-v1', maxNativeBytes: DEFAULT_NATIVE_BYTES, toolLoopNativeFileBlock: null,
  },
  grok_subscription_chat: textOnly('xml-v1'),
  // Not verified against the real provider: whether the Grok subscription Responses backend reads input_file is unknown.
  grok_subscription_responses: {
    nativeFileBlock: 'input_file',
    nativeFiles: 'alwaysWithTextFallback',
    wrapper: 'xml-v1', maxNativeBytes: DEFAULT_NATIVE_BYTES, toolLoopNativeFileBlock: null,
  },

  // -- Relay: varies by site, not verified against the real provider, falls back to text when rejected --
  relay_openai_chat: textOnly('xml-v1'),
  // Not verified against the real provider: whether a relay passes input_file through varies by site.
  relay_openai_responses: {
    nativeFileBlock: 'input_file',
    nativeFiles: 'alwaysWithTextFallback',
    wrapper: 'xml-v1', maxNativeBytes: DEFAULT_NATIVE_BYTES, toolLoopNativeFileBlock: null,
  },
  // Not verified against the real provider: whether a relay passes document through varies by site.
  relay_anthropic_messages: {
    nativeFileBlock: 'document',
    nativeFiles: 'alwaysWithTextFallback',
    wrapper: 'xml-v1', maxNativeBytes: DEFAULT_NATIVE_BYTES, toolLoopNativeFileBlock: null,
  },
  // Not verified against the real provider: whether a relay passes inlineData through varies by site.
  relay_gemini_generate: {
    nativeFileBlock: 'inline_data',
    nativeFiles: 'alwaysWithTextFallback',
    wrapper: 'xml-v1', maxNativeBytes: GEMINI_NATIVE_BYTES, toolLoopNativeFileBlock: null,
  },
  // The whole conversation is folded into one prompt with text only; a placeholder tells the model an image did not arrive.
  relay_llamacpp_native: textOnly('xml-v1', TEXT_ONLY_ROUTE_IMAGE_PLACEHOLDER),
} as const satisfies Record<AttachmentTransport, AttachmentTransportProfile>;

export function attachmentTransportProfile(transport: AttachmentTransport): AttachmentTransportProfile {
  return PROFILES[transport];
}

/** The line of one send: the outbound transport + whether this request carries client tools (the tool leg's message conversion is separate code). */
export interface AttachmentLine {
  transport: AttachmentTransport;
  toolLoop?: boolean;
  /**
   * Treat the line as `off` for this send: this connection has already rejected file blocks (a fallback resend, or remembered during this page session).
   */
  nativeFilesSuppressed?: boolean;
}

/** The native level actually in effect for this send: `off` when the tool leg has no native block, or when this connection has already rejected file blocks. */
export function nativeFileModeOf(line: AttachmentLine): NativeFileMode {
  const profile = PROFILES[line.transport];
  if (line.nativeFilesSuppressed) return 'off';
  if (line.toolLoop && profile.toolLoopNativeFileBlock === null) return 'off';
  return profile.nativeFiles;
}

/** The native block a `file` part becomes on this send (regardless of level). */
export function nativeFileBlockOf(line: AttachmentLine): NativeFileBlock | null {
  const profile = PROFILES[line.transport];
  return line.toolLoop ? profile.toolLoopNativeFileBlock : profile.nativeFileBlock;
}

/* -- Line resolution ------------------------------------------- */

export type OutboundWire =
  | 'openai_chat'
  | 'openai_responses'
  | 'anthropic_messages'
  | 'gemini_generate'
  | 'gemini_interactions';

/**
 * Which protocol an already built outbound request uses. The tool leg's message conversion
 * (`applyToolCallWireAdapter`) uses the same URL test, and the contrast test pins the two together.
 */
export function outboundWireOf(request: Pick<ProviderRequest, 'url' | 'responseAdapter'>): OutboundWire {
  if (request.responseAdapter === 'gemini_interactions') return 'gemini_interactions';
  if (/\/responses(?:\?|$)/.test(request.url)) return 'openai_responses';
  if (/\/messages(?:\?|$)/.test(request.url)) return 'anthropic_messages';
  if (/:streamGenerateContent(?:\?|$)|:generateContent(?:\?|$)/.test(request.url)) return 'gemini_generate';
  return 'openai_chat';
}

const OFFICIAL_CHAT_TRANSPORT: Partial<Record<ProviderKind, AttachmentTransport>> = {
  openAI: 'openai_chat',
  openRouter: 'openrouter_chat',
  grok: 'grok_chat',
  miniMax: 'minimax_chat',
  deepseek: 'deepseek_chat',
  qwen: 'qwen_chat',
  moonshot: 'moonshot_chat',
  zhipu: 'zhipu_chat',
  siliconFlow: 'siliconflow_chat',
  togetherAI: 'openai_compatible_chat',
  groq: 'openai_compatible_chat',
  fireworksAI: 'openai_compatible_chat',
  mistral: 'openai_compatible_chat',
  // Relay requests through /api/chat/stream (the tool leg) are always Chat Completions.
  relay: 'relay_openai_chat',
};

/**
 * Which line a request produced by the `/api/chat/stream` dispatch (`buildProviderRequest`) belongs to.
 * An unrecognized combination returns `null`; callers treat it as "no native block".
 */
export function dispatchedAttachmentTransport(
  providerKind: ProviderKind | string,
  wire: OutboundWire,
): AttachmentTransport | null {
  switch (providerKind) {
    case 'openAI':
      return wire === 'openai_responses' ? 'openai_responses' : wire === 'openai_chat' ? 'openai_chat' : null;
    case 'anthropic':
      return wire === 'anthropic_messages' ? 'anthropic_messages' : null;
    case 'gemini':
      return wire === 'gemini_interactions'
        ? 'gemini_interactions'
        : wire === 'gemini_generate' ? 'gemini_generate' : null;
    case 'grok':
      return wire === 'openai_responses' ? 'grok_responses' : wire === 'openai_chat' ? 'grok_chat' : null;
    case 'miniMax':
      return wire === 'anthropic_messages'
        ? 'minimax_anthropic_messages'
        : wire === 'openai_chat' ? 'minimax_chat' : null;
    default:
      return wire === 'openai_chat'
        ? OFFICIAL_CHAT_TRANSPORT[providerKind as ProviderKind] ?? null
        : null;
  }
}

/** Conservative fallback when the line cannot be determined: the provider's Chat line without a native block (files are always injected as text). */
export function fallbackTextAttachmentTransport(providerKind: ProviderKind | string): AttachmentTransport {
  switch (providerKind) {
    case 'anthropic':
    case 'gemini':
      // These two have no line without a native block; fall back to the generic xml text line.
      return 'openai_compatible_chat';
    default:
      return OFFICIAL_CHAT_TRANSPORT[providerKind as ProviderKind] ?? 'openai_compatible_chat';
  }
}

export type RelayAttachmentProtocol =
  | 'openai_responses'
  | 'openai_chat_completions'
  | 'anthropic_messages'
  | 'gemini_generate_content'
  | 'llamacpp_native';

/** The line of a relay sent directly from the browser or through the proxy (`sendRelayStream`); one-to-one with its `transport` branches. */
export function relayAttachmentTransport(protocol: RelayAttachmentProtocol | undefined): AttachmentTransport {
  switch (protocol) {
    case 'openai_responses':
      return 'relay_openai_responses';
    case 'anthropic_messages':
      return 'relay_anthropic_messages';
    case 'gemini_generate_content':
      return 'relay_gemini_generate';
    case 'llamacpp_native':
      return 'relay_llamacpp_native';
    case 'openai_chat_completions':
    default:
      return 'relay_openai_chat';
  }
}

/** The Grok subscription protocol is decided by the model's upstream declaration; without one the server-side configuration decides and the client cannot tell. */
export function grokSubscriptionAttachmentTransport(apiBackend: string | undefined): AttachmentTransport | null {
  const normalized = apiBackend?.trim().toLowerCase();
  if (normalized === 'responses') return 'grok_subscription_responses';
  if (normalized === 'chat' || normalized === 'chat_completions' || normalized === 'chat.completions') {
    return 'grok_subscription_chat';
  }
  return null;
}

/* -- Last gate before sending ---------------------------------- */

export const ATTACHMENT_TRANSPORT_MISMATCH = 'attachment_transport_mismatch';

/** The request carries a native `file` part but the actual outbound line does not accept it: the request is not sent. */
export class AttachmentTransportMismatchError extends Error {
  readonly code = ATTACHMENT_TRANSPORT_MISMATCH;
  constructor(readonly transport: AttachmentTransport | null) {
    super(ATTACHMENT_TRANSPORT_MISMATCH);
    this.name = 'AttachmentTransportMismatchError';
  }
}

/**
 * The client built native `file` parts for the line it predicted; if the line actually selected does not
 * accept them, this raises an error instead of letting a builder's fallback branch lose the file and send anyway.
 */
export function messagesCarryFilePart(
  messages: ReadonlyArray<{ content: string | ContentPart[] }>,
): boolean {
  return messages.some((message) => typeof message.content !== 'string'
    && message.content.some((part) => part.type === 'file'));
}

export function assertFilePartsDeliverable(
  line: { transport: AttachmentTransport | null; toolLoop?: boolean },
  messages: ReadonlyArray<{ content: string | ContentPart[] }>,
): void {
  if (!messagesCarryFilePart(messages)) return;
  if (line.transport === null
    || nativeFileModeOf({ transport: line.transport, toolLoop: line.toolLoop }) === 'off') {
    throw new AttachmentTransportMismatchError(line.transport);
  }
}
