/**
 * Which outbound line this send takes (used for attachment delivery).
 *
 * The pre-send check and the outbound history build (`buildChatHistory`) both call this one function with
 * the same inputs (connection, model, stream options derived from intent, whether client tools are
 * attached), so the two never judge separately.
 *
 * The line for a direct official connection is decided by `buildProviderRequest` on the `/api/chat/stream`
 * side (one provider switches between Chat / Responses and generateContent / Interactions depending on
 * metadata and this turn's options). This does not restate that logic: it runs the same builder dry with the
 * browser's copy of the same metadata and looks at which endpoint it picked. When the request really goes
 * out, the route checks once more against the line actually selected (`assertFilePartsDeliverable`).
 */
import type { AIModel, ChatMessage, Provider } from '@oriveo/shared';
import {
  type AttachmentLine,
  dispatchedAttachmentTransport,
  fallbackTextAttachmentTransport,
  grokSubscriptionAttachmentTransport,
  outboundWireOf,
  relayAttachmentTransport,
} from '@oriveo/core/providers/attachment-transport';
import { buildProviderRequest, type MetadataProvider } from '@oriveo/core/providers/request-builders/dispatch';
import type { RequestParams } from '@oriveo/core/providers/request-builders/types';
import type { StreamOptions } from '../providers/types';
import { browserOfficialMetadata, DEFAULT_RELAY_RUNTIME_CONFIG, getRelayRuntimeConfig } from '../metadata/metadata-client';
import { isMoonshotChinaBaseURL } from '../providers/adapters/moonshot';
import { relayFirstSendTransport } from '../providers/relay-first-send-transport';
import { connectionRejectsNativeFiles, nativeFileInputTarget } from './native-file-fallback';
import { relayInputOverrideValue } from '../capability/capability-overrides';
import type { RelayNegativeCacheModelKey } from '../chat/relay-negative-cache';
import { requestBaseURLText } from '../providers/endpoint-source';
import { applyOutboundAttachmentBudget } from './outbound-attachment-budget';
import { imageSizeBytes } from '../../infra/storage/image-store';

export interface ResolvedAttachmentLine extends AttachmentLine {
  /**
   * The line was determined exactly. `false` = it cannot be determined (catalog not loaded, subscription
   * protocol undeclared, or the builder rejected this turn's options); `transport` is then the provider's
   * conservative text line: files arrive as text when the history is built, and the pre-send check does not
   * block, leaving it to send time.
   */
  exact: boolean;
}

/**
 * Key under which a relay's native-file rejection is recorded in the local negative cache (connection x model
 * x the protocol actually sent this turn); the send side writes the same key. `sentTransport` is the
 * relayTransport of this turn's dispatch params (Chat when an attachment falls back to Chat); when omitted
 * it defaults to the first-send protocol, not the effective protocol. Returns undefined for other kinds and
 * when the connection id is unavailable (the in-process connection x line memory applies then).
 */
export function relayNativeFileCacheKey(
  provider: Provider,
  model: AIModel,
  sentTransport?: string,
): RelayNegativeCacheModelKey | undefined {
  if (provider.kind !== 'relay' || !provider.id) return undefined;
  return {
    connectionId: provider.id,
    modelId: model.id,
    transport: sentTransport ?? relayFirstSendTransport(provider, model),
  };
}

/** The envelope of this relay protocol (delivered by metadata, built-in default otherwise) explicitly does not accept native files. */
function relayEnvelopeRejectsNativeFile(protocol: StreamOptions['relayTransport']): boolean {
  const key = protocol ?? 'openai_chat_completions';
  if (key === 'llamacpp_native') return true;
  const envelope = getRelayRuntimeConfig().transportEnvelopes[key] ?? DEFAULT_RELAY_RUNTIME_CONFIG.transportEnvelopes[key];
  return envelope?.nativeFile === false;
}

export interface AttachmentLineInput {
  provider: Pick<Provider, 'kind' | 'authMode' | 'baseURLText'> & Partial<Pick<Provider, 'id' | 'relayRequested'>>;
  model: Pick<AIModel, 'id' | 'upstreamApiBackend'> & Partial<Pick<AIModel, 'relayTransport' | 'relayCapabilityOverrides' | 'capabilityOverrides'>>;
  /** The result of `buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(...), model)`. */
  streamOptions?: StreamOptions;
  /** This request carries client tools (MCP / library agent leg). */
  toolLoop?: boolean;
  /** Metadata the builder uses for an official connection; defaults to the browser-side /api/metadata payload. */
  officialMetadata?: MetadataProvider;
  /** The outbound history (including the current turn) carries a video attachment: Gemini then does not pick Interactions, and the dry run must carry the same fact. */
  historyHasVideo?: boolean;
}

export async function resolveAttachmentLine(input: AttachmentLineInput): Promise<ResolvedAttachmentLine> {
  const { provider, model, streamOptions } = input;
  const toolLoop = input.toolLoop === true;
  const exact = (transport: AttachmentLine['transport']): ResolvedAttachmentLine => ({
    transport,
    toolLoop,
    exact: true,
    // This connection already rejected file blocks: go straight to text and skip the extra round trip. Relays and official connections read the local `file_input` negative cache v2.
    ...(connectionRejectsNativeFiles(provider.id, transport, nativeFileInputTarget(provider, model, streamOptions))
      ? { nativeFilesSuppressed: true } : {}),
  });
  const unknown = (): ResolvedAttachmentLine => ({
    transport: fallbackTextAttachmentTransport(provider.kind),
    toolLoop,
    exact: false,
  });

  if (provider.kind === 'relay') {
    // A relay request with tools goes through /api/chat/stream and is always Chat Completions.
    const transport = toolLoop ? 'relay_openai_chat' : relayAttachmentTransport(streamOptions?.relayTransport);
    const fileOverride = relayInputOverrideValue(model, 'file_input')?.value;
    if (typeof fileOverride !== 'boolean') return exact(transport);
    // File override: Off always means text; On beats the `file` negative cache, but text still applies when the protocol envelope does not accept native files.
    const suppressed = !fileOverride
      || relayEnvelopeRejectsNativeFile(toolLoop ? 'openai_chat_completions' : streamOptions?.relayTransport);
    return { transport, toolLoop, exact: true, ...(suppressed ? { nativeFilesSuppressed: true } : {}) };
  }
  if (provider.authMode === 'subscription' && provider.kind === 'openAI') {
    return exact('openai_subscription_codex');
  }
  if (provider.authMode === 'subscription' && provider.kind === 'grok') {
    const transport = grokSubscriptionAttachmentTransport(model.upstreamApiBackend);
    return transport ? exact(transport) : { transport: 'grok_subscription_chat', toolLoop, exact: false };
  }
  // Same test as `shouldUseBrowserDirectStream` in `sendStream`; the tool leg still goes through /api/chat/stream.
  if (provider.kind === 'moonshot' && !toolLoop && isMoonshotChinaBaseURL(requestBaseURLText(provider))) {
    return exact('moonshot_browser_direct');
  }

  try {
    const metadata = await (input.officialMetadata ?? (() => browserOfficialMetadata(provider.kind)))();
    if (!metadata) return unknown();
    const request = await buildProviderRequest({
      providerKind: provider.kind,
      apiKey: '',
      modelID: model.id,
      messages: [{
        role: 'user',
        content: input.historyHasVideo
          ? [{ type: 'text', text: '' }, { type: 'video_url', video_url: { url: 'data:video/mp4;base64,' } }]
          : '',
      }],
      ...(requestBaseURLText(provider) ? { baseURL: requestBaseURLText(provider) } : {}),
      ...(streamOptions ? { options: streamOptions as RequestParams['options'] } : {}),
    }, async () => metadata);
    const transport = dispatchedAttachmentTransport(provider.kind, outboundWireOf(request));
    return transport ? exact(transport) : unknown();
  } catch {
    return unknown();
  }
}

/**
 * Whether the outbound history has a video attachment: any attachment of kind video counts, whether or not
 * its bytes are loaded. The input is the messages this request actually sends (buildOutboundMessages); they
 * go through the same history attachment budget window as buildChatHistory, and a historical video that the
 * budget drops whole and replaces with a placeholder line is not sent, so it does not count.
 */
export async function outboundHistoryHasVideo(messages: ReadonlyArray<ChatMessage>): Promise<boolean> {
  const isVideo = (message: ChatMessage) => message.attachments?.some((attachment) => attachment.kind === 'video') === true;
  if (!messages.some(isVideo)) return false;
  const budgeted = await applyOutboundAttachmentBudget([...messages], { imageSizeOf: imageSizeBytes });
  return budgeted.some(isVideo);
}

/**
 * Resolves the line only when the outbound messages carry file attachments; without files the line does not affect the history build, so this returns `undefined`.
 */
export async function resolveAttachmentLineForMessages(
  messages: ReadonlyArray<ChatMessage>,
  input: AttachmentLineInput,
): Promise<ResolvedAttachmentLine | undefined> {
  const hasFile = messages.some((message) => message.attachments?.some((attachment) => attachment.kind === 'file'));
  if (!hasFile) return undefined;
  const historyHasVideo = await outboundHistoryHasVideo(messages);
  return resolveAttachmentLine(historyHasVideo ? { ...input, historyHasVideo } : input);
}
