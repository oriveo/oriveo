/**
 * Desktop chat streaming renderer transport.
 *
 * Wraps the StreamEvents that main sends over a MessagePort into a ReadableStream<StreamEvent> so
 * the layers above can keep using readStream unchanged.
 *
 * Port transfer follows the standard Electron pattern: preload creates a MessageChannel, sends port2
 * to main through ipcRenderer.postMessage, and forwards port1 into this main world with
 * window.postMessage('oriveo:chat-stream-port',[port1]). The renderer therefore installs its window
 * 'message' listener first, claims port1 after checking event.source===window and the streamId, and
 * only then calls startStream, which avoids the race.
 *
 * Covers the text path for official and relay providers (relay goes through RelayChatStreamRequest).
 * Plaintext keys never cross IPC: the keyRef is bound to the account partition and the provider, and
 * main decrypts through KeyVault.get(keyRef).
 */
import type { ProviderKind } from '@oriveo/shared';
import type {
  ChatContentPart,
  ChatRequestMessage,
  ChatStreamOptions,
  ChatStreamRequest,
  OfficialChatStreamRequest,
  OfficialProviderKind,
  RelayChatStreamRequest,
} from '@oriveo/ipc-contract';
import type { ChatStreamClosed, ChatStreamEnvelope } from '@oriveo/core/chat/ipc-stream';
import type { ContentPart, StreamEvent, StreamHandle, StreamOptions } from './types';

const PORT_RELAY_TAG = 'oriveo:chat-stream-port';

type CoreMessage = { role: 'user' | 'assistant' | 'system'; content: string | ContentPart[] };

/** Desktop runtime detection: preload exposing window.oriveo.chat means desktop. Always false on web. */
export const IS_DESKTOP = typeof window !== 'undefined' && Boolean(window.oriveo?.chat);

function dataUrlMime(dataUrl: string): string {
  const m = dataUrl.match(/^data:([^;]+)/);
  return m ? m[1] : 'application/octet-stream';
}

/**
 * ContentPart -> wire ChatContentPart. **On desktop imageRef/dataRef carry an inline data URL**
 * (IPC cannot share the renderer image store, the renderer has already inlined it, and main uses it
 * as a data URL). video_url is dropped because the wire contract has no video variant yet, which is
 * rare since most multimodal input is images or PDF files.
 */
function toWireContent(content: string | ContentPart[]): string | ChatContentPart[] {
  if (typeof content === 'string') return content;
  const parts: ChatContentPart[] = [];
  for (const p of content) {
    if (p.type === 'text') {
      parts.push({ type: 'text', text: p.text });
    } else if (p.type === 'image_url') {
      parts.push({
        type: 'image',
        imageRef: p.image_url.url,
        mimeType: dataUrlMime(p.image_url.url),
        ...(p.image_url.detail ? { detail: p.image_url.detail } : {}),
      });
    } else if (p.type === 'video_url') {
      parts.push({ type: 'video', videoRef: p.video_url.url, mimeType: dataUrlMime(p.video_url.url) });
    } else if (p.type === 'file') {
      parts.push({
        type: 'file',
        fileName: p.file.filename,
        mimeType: p.file.mimeType ?? dataUrlMime(p.file.file_data),
        dataRef: p.file.file_data,
        ...(p.file.extractedTotalLines !== undefined ? { extractedTotalLines: p.file.extractedTotalLines } : {}),
        ...(p.file.extractedTruncated !== undefined ? { extractedTruncated: p.file.extractedTruncated } : {}),
        ...(p.file.extractedSizeBytes !== undefined ? { extractedSizeBytes: p.file.extractedSizeBytes } : {}),
        ...(p.file.extractionErrorCode ? { extractionErrorCode: p.file.extractionErrorCode } : {}),
      });
    }
  }
  return parts;
}

export function toWireMessages(messages: CoreMessage[]): ChatRequestMessage[] {
  return messages.map((m) => ({ role: m.role, content: toWireContent(m.content) }));
}

export function toWireOptions(options: StreamOptions | undefined): ChatStreamOptions | undefined {
  if (!options) return undefined;
  const out: ChatStreamOptions = {};
  if (options.reasoning) out.reasoningMode = options.reasoning;
  if (options.supportsWebSearch) out.webSearchEnabled = true;
  if (options.supportsImageGen) out.imageGenEnabled = true;
  if (options.generationParameters) out.generationParameters = options.generationParameters;
  if (options.relayServiceTier) out.relayServiceTier = options.relayServiceTier;
  if (options.relayReasoningEffort) out.relayReasoningEffort = options.relayReasoningEffort;
  if (options.relayStream !== undefined) out.relayStream = options.relayStream;
  if (options.relayDisableResponseStorage !== undefined) out.relayDisableResponseStorage = options.relayDisableResponseStorage;
  if (options.relayWebSearchToolName) out.relayWebSearchToolName = options.relayWebSearchToolName;
  if (options.relayHeaders) out.relayHeaders = options.relayHeaders;
  if (options.relayQueryParams) out.relayQueryParams = options.relayQueryParams;
  if (options.relayCodexCompatIdentity !== undefined) out.relayCodexCompatIdentity = options.relayCodexCompatIdentity;
  if (options.relayCustomUserAgent) out.relayCustomUserAgent = options.relayCustomUserAgent;
  // Only the renderer holds the connection identity used for rejected-parameter self-healing (local
  // identity storage plus the metadata ETag), and main cannot reconstruct it; without it main would have to gamble on a 400 for every message. These are opaque irreversible identifiers and contain no key or URL.
  if (options.capabilityIdentity) out.capabilityIdentity = options.capabilityIdentity;
  return Object.keys(out).length > 0 ? out : undefined;
}

function buildWireRequest(
  kind: ProviderKind,
  keyRef: string,
  modelID: string,
  messages: CoreMessage[],
  options: StreamOptions | undefined,
  streamId: string,
  baseURL: string | undefined,
): ChatStreamRequest {
  const wireOptions = toWireOptions(options);
  // main does not use conversationId, so streamId is passed as a placeholder.
  if (kind === 'relay') {
    // relay: transport and authMode were already resolved in options by resolveRelayRuntimeFields, and baseURL is the resolved endpoint.
    const relayReq: RelayChatStreamRequest = {
      providerKind: 'relay',
      apiKeyRef: keyRef,
      conversationId: streamId,
      modelID,
      messages: toWireMessages(messages),
      relay: {
        baseURL: options?.relayResolvedBaseURLText ?? baseURL ?? '',
        transport: options?.relayTransport ?? 'openai_chat_completions',
        authMode: options?.relayAuthMode ?? 'bearer',
      },
      ...(wireOptions ? { options: wireOptions } : {}),
    };
    return relayReq;
  }
  const req: OfficialChatStreamRequest = {
    providerKind: kind as OfficialProviderKind,
    apiKeyRef: keyRef,
    conversationId: streamId,
    modelID,
    messages: toWireMessages(messages),
    // Official custom endpoint override (self-hosted, openai-compatible, or a proxy); when empty, main falls back to the kind default.
    ...(baseURL ? { baseURL } : {}),
    ...(wireOptions ? { options: wireOptions } : {}),
  };
  return req;
}

function arrayBufferToDataURL(mime: string, buf: ArrayBuffer): string {
  const bytes = new Uint8Array(buf);
  let binary = '';
  for (let i = 0; i < bytes.length; i += 1) binary += String.fromCharCode(bytes[i]);
  return `data:${mime};base64,${btoa(binary)}`;
}

export function sendStreamDesktop(
  kind: ProviderKind,
  keyRef: string,
  modelID: string,
  messages: CoreMessage[],
  baseURL: string | undefined,
  options: StreamOptions | undefined,
): StreamHandle {
  const streamId = crypto.randomUUID();
  let cancelled = false;
  let claimedPort: MessagePort | null = null;
  let sawErrorEvent = false;

  const stream = new ReadableStream<StreamEvent>({
    start(ctrl) {
      const onWindowMessage = (e: MessageEvent): void => {
        const data = e.data as { tag?: string; streamId?: string } | null;
        if (e.source !== window || data?.tag !== PORT_RELAY_TAG || data.streamId !== streamId) return;
        window.removeEventListener('message', onWindowMessage);
        const port = e.ports[0];
        if (!port) {
          ctrl.error(new Error('chat stream: no MessagePort received'));
          return;
        }
        claimedPort = port;
        port.onmessage = (me: MessageEvent): void => {
          const msg = me.data as ChatStreamEnvelope | ChatStreamClosed;
          if ('reason' in msg) {
            // Terminal signals (done/cancelled/error): close the ReadableStream.
            try {
              port.close();
            } catch {
              /* already closed */
            }
            if (msg.reason === 'error' && !sawErrorEvent) {
              ctrl.error(new Error('Desktop stream failed'));
            } else {
              ctrl.close();
            }
            return;
          }
          if ('eventKind' in msg && msg.eventKind === 'image') {
            ctrl.enqueue({ type: 'image', url: arrayBufferToDataURL(msg.mime, msg.data) });
          } else if ('event' in msg) {
            if (msg.event.type === 'error') sawErrorEvent = true;
            ctrl.enqueue(msg.event);
          }
        };
        port.start();
      };
      window.addEventListener('message', onWindowMessage);

      const req = buildWireRequest(kind, keyRef, modelID, messages, options, streamId, baseURL);
      window.oriveo!.chat.startStream(streamId, req);
      if (cancelled) window.oriveo!.chat.cancelStream(streamId);
    },
    cancel() {
      cancelled = true;
      window.oriveo?.chat.cancelStream(streamId);
      try {
        claimedPort?.close();
      } catch {
        /* noop */
      }
    },
  });

  return {
    stream,
    abort: () => {
      cancelled = true;
      window.oriveo?.chat.cancelStream(streamId);
    },
  };
}
