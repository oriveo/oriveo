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
import { browserOfficialMetadata } from '../metadata/metadata-client';
import { isMoonshotChinaBaseURL } from '../providers/adapters/moonshot';
import { connectionRejectsNativeFiles } from './native-file-fallback';

export interface ResolvedAttachmentLine extends AttachmentLine {
  /**
   * The line was determined exactly. `false` = it cannot be determined (catalog not loaded, subscription
   * protocol undeclared, or the builder rejected this turn's options); `transport` is then the provider's
   * conservative text line: files arrive as text when the history is built, and the pre-send check does not
   * block, leaving it to send time.
   */
  exact: boolean;
}

export interface AttachmentLineInput {
  provider: Pick<Provider, 'kind' | 'authMode' | 'baseURLText'> & Partial<Pick<Provider, 'id'>>;
  model: Pick<AIModel, 'id' | 'upstreamApiBackend'>;
  /** The result of `buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(...), model)`. */
  streamOptions?: StreamOptions;
  /** This request carries client tools (MCP / library agent leg). */
  toolLoop?: boolean;
  /** Metadata the builder uses for an official connection; defaults to the browser-side /api/metadata payload. */
  officialMetadata?: MetadataProvider;
}

export async function resolveAttachmentLine(input: AttachmentLineInput): Promise<ResolvedAttachmentLine> {
  const { provider, model, streamOptions } = input;
  const toolLoop = input.toolLoop === true;
  const exact = (transport: AttachmentLine['transport']): ResolvedAttachmentLine => ({
    transport,
    toolLoop,
    exact: true,
    // This connection already rejected file blocks during this page session (a fallback resend succeeded): go straight to text and skip the extra round trip.
    ...(connectionRejectsNativeFiles(provider.id, transport) ? { nativeFilesSuppressed: true } : {}),
  });
  const unknown = (): ResolvedAttachmentLine => ({
    transport: fallbackTextAttachmentTransport(provider.kind),
    toolLoop,
    exact: false,
  });

  if (provider.kind === 'relay') {
    // A relay request with tools goes through /api/chat/stream and is always Chat Completions.
    return exact(toolLoop ? 'relay_openai_chat' : relayAttachmentTransport(streamOptions?.relayTransport));
  }
  if (provider.authMode === 'subscription' && provider.kind === 'openAI') {
    return exact('openai_subscription_codex');
  }
  if (provider.authMode === 'subscription' && provider.kind === 'grok') {
    const transport = grokSubscriptionAttachmentTransport(model.upstreamApiBackend);
    return transport ? exact(transport) : { transport: 'grok_subscription_chat', toolLoop, exact: false };
  }
  // Same test as `shouldUseBrowserDirectStream` in `sendStream`; the tool leg still goes through /api/chat/stream.
  if (provider.kind === 'moonshot' && !toolLoop && isMoonshotChinaBaseURL(provider.baseURLText)) {
    return exact('moonshot_browser_direct');
  }

  try {
    const metadata = await (input.officialMetadata ?? (() => browserOfficialMetadata(provider.kind)))();
    if (!metadata) return unknown();
    const request = await buildProviderRequest({
      providerKind: provider.kind,
      apiKey: '',
      modelID: model.id,
      messages: [{ role: 'user', content: '' }],
      ...(provider.baseURLText ? { baseURL: provider.baseURLText } : {}),
      ...(streamOptions ? { options: streamOptions as RequestParams['options'] } : {}),
    }, async () => metadata);
    const transport = dispatchedAttachmentTransport(provider.kind, outboundWireOf(request));
    return transport ? exact(transport) : unknown();
  } catch {
    return unknown();
  }
}

/**
 * Resolves the line only when the outbound messages carry file attachments; without files the line does not affect the history build, so this returns `undefined`.
 */
export async function resolveAttachmentLineForMessages(
  messages: ReadonlyArray<Pick<ChatMessage, 'attachments'>>,
  input: AttachmentLineInput,
): Promise<ResolvedAttachmentLine | undefined> {
  const hasFile = messages.some((message) => message.attachments?.some((attachment) => attachment.kind === 'file'));
  return hasFile ? resolveAttachmentLine(input) : undefined;
}
