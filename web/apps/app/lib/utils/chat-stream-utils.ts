/**
 * Pure helpers for chat streaming, extracted from the useStreamChat hook so they
 * carry no React dependency.
 */
import type { ChatMessage, Attachment, Citation, AIModel } from '@oriveo/shared';
import { buildEffectiveUserContent } from '@oriveo/shared';
import type { StreamEvent, OpenRouterUsage, ContentPart } from '../core/providers/service';
import type { ContinuationIntent } from '@oriveo/core/providers/request-preference/continuation';
import type { ProviderError } from '../core/providers/errors';
import {
  finalizeToolCalls,
  mergeToolCallDeltas,
  type CompletedToolCall,
  type ToolCallAccumulator,
} from '@oriveo/core/providers/tool-call-accumulator';
import { imageSizeBytes, loadImageBase64 } from '../infra/storage/image-store';
import { createCanonicalUUID } from './id-utils';
import {
  type AttachmentPayload,
  type AttachmentWrapperVersion,
  AttachmentInjector,
  resolveWrapperVersion,
} from '../core/attachments/attachment-injector';
import {
  resolveFileExtractionLimits,
} from '../core/attachments/file-text-extractor';
import { decideAttachmentRoute } from '../core/attachments/attachment-router';
import { applyOutboundAttachmentBudget } from '../core/attachments/outbound-attachment-budget';

/**
 * Build the chat history sent to a provider, including content parts.
 * Converts local ChatMessage[] into the shape the API expects.
 *
 * @param msgs message list
 * @param currentModel selected model; decides the truncation threshold and the fallback path
 * @param providerKind selected provider kind; decides the wrapper format
 */
export async function buildChatHistory(
  msgs: ChatMessage[],
  currentModel?: AIModel | null,
  providerKind?: string,
): Promise<{ role: 'user' | 'assistant' | 'system'; content: string | ContentPart[] }[]> {
  const limits = resolveFileExtractionLimits(currentModel);
  const wrapper: AttachmentWrapperVersion = providerKind
    ? resolveWrapperVersion(providerKind)
    : 'xml-v1';

  // Historical attachment budget window (see outbound-attachment-budget.ts): the current turn is
  // never trimmed, over-budget historical images/videos degrade to placeholder lines, and historical
  // files keep their extracted text while dropping the raw bytes. This must run before the loop below:
  // image base64 is only read out of IndexedDB by loadImageBase64 inside that loop, so dropping an
  // attachment earlier means the read never happens at all.
  const budgetedMsgs = await applyOutboundAttachmentBudget(msgs, { imageSizeOf: imageSizeBytes });

  const result: { role: 'user' | 'assistant' | 'system'; content: string | ContentPart[] }[] = [];
  for (const m of budgetedMsgs) {
    // QuoteContext is expanded only at the unified provider boundary. BYOK, relay, managed and
    // library sends all go through buildChatHistory, so the local message.text always keeps the
    // original user input.
    const effectiveText = m.role === 'user'
      ? buildEffectiveUserContent(m.text, m.quoteContext)
      : m.text;
    if (m.attachments && m.attachments.length > 0) {
      const parts: ContentPart[] = [];
      const filePayloads: AttachmentPayload[] = [];
      let hasNativePdfFallback = false;

      if (m.text) {
        // Hold the text aside; AttachmentInjector.injectAll assembles it further down.
      }

      for (const att of m.attachments) {
        if (att.kind === 'image') {
          let b64 = att.localImageID ? await loadImageBase64(att.localImageID) : null;
          if (!b64) b64 = att.base64Data ?? null;
          if (b64) {
            parts.push({
              type: 'image_url',
              // Send detail=auto explicitly so a future low/high UI toggle has something to build on.
              image_url: { url: `data:${att.mimeType};base64,${b64}`, detail: 'auto' },
            });
          }
        } else if (att.kind === 'video' && att.base64Data) {
          parts.push({
            type: 'video_url',
            video_url: { url: `data:${att.mimeType};base64,${att.base64Data}` },
          });
        } else if (att.kind === 'file') {
          // AttachmentRouter is the single place that decides native vs client_extract, replacing
          // scattered scanned_pdf + capabilities.native_pdf checks.
          const route = currentModel
            ? decideAttachmentRoute(att, providerKind ?? '', currentModel)
            : 'client_extract';
          if (route === 'native' && att.originalBase64Data) {
            parts.push({
              type: 'file',
              file: {
                filename: att.fileName,
                file_data: `data:${att.mimeType};base64,${att.originalBase64Data}`,
                mimeType: att.mimeType,
                extractionErrorCode: att.extractionErrorCode,
              },
            });
            hasNativePdfFallback = true;
          } else {
            // client_extract: build an ATTACHMENT_FILE text block via AttachmentInjector.
            const extracted = att.base64Data
              ? {
                  content: att.base64Data,
                  totalLines: att.extractedTotalLines ?? att.base64Data.split('\n').length,
                  truncated: att.extractedTruncated ?? false,
                  truncationReason: undefined as ('lines' | 'bytes' | undefined),
                  sizeBytes: att.extractedSizeBytes ?? att.base64Data.length,
                }
              : null;
            filePayloads.push({
              fileName: att.fileName,
              mimeType: att.mimeType,
              sizeBytes: att.extractedSizeBytes ?? att.base64Data?.length ?? 0,
              extracted,
              errorCode: att.extractionErrorCode as (import('../core/attachments/file-text-extractor').ExtractionErrorCode | undefined),
            });
          }
        }
      }

      // Append filePayloads to the end of userText via AttachmentInjector.
      const { text: combinedText, skipped } = AttachmentInjector.injectAll(
        effectiveText ?? '',
        filePayloads,
        limits,
        wrapper,
      );

      // Skipped-attachment telemetry is consumed by the caller; return it through the extension field.
      if (skipped.length > 0) {
        // Telemetry is handled upstream. Here we only append a note to combinedText so the model
        // knows. The actual UI toast is raised in operations.ts (TODO: pass skipped info upwards).
      }

      // When there are attachments, this message's text already contains the ATTACHMENT_FILE block;
      // the matching system prompt guidance is appended in buildSystemPromptContent in operations.ts.
      if (combinedText.trim() || parts.length > 0) {
        if (combinedText.trim()) {
          parts.unshift({ type: 'text', text: combinedText });
        }
        result.push({ role: m.role, content: parts.length > 0 ? parts : combinedText });
      } else {
        result.push({ role: m.role, content: effectiveText ?? '' });
      }
    } else {
      result.push({ role: m.role, content: effectiveText });
    }
  }
  return result;
}

/**
 * Normalize outbound messages before sending.
 *
 * Two steps:
 * 1. Filter: drop messages with empty content (no text and no attachments); keep every user message,
 *    plus non-failed assistant history that has content (delivered, an interrupted partial the user
 *    stopped, or a partial still generating when a race prevented finalize) and the explicit
 *    continue/retry target (keepAssistantId). Only failed turns are dropped: a failed exchange is not
 *    context, and its empty placeholder gets filled with a localized error string on some clients, so
 *    keeping it would send that error text to the model as a fake answer.
 * 2. Collapse adjacent same-role messages: once step 1 removes an empty assistant in the middle, the
 *    two user messages it separated become adjacent and roles no longer alternate. Strict
 *    OpenAI-compatible relays require user/assistant to alternate and reject consecutive same-role
 *    messages outright.
 *    - Adjacent user: drop the earlier one and keep only the latest. The earlier question already
 *      failed or was abandoned, and merging two independent questions into one prompt makes the model
 *      answer both at once.
 *    - Adjacent assistant (rare): merge text (joined by a blank line) and attachments (in order) so
 *      nothing is lost.
 *
 * Note: an interrupted assistant that still has partial text naturally separates the two surrounding
 * user messages, so the adjacent-user path is usually never reached; it only triggers when the stop
 * happened early enough that the partial is empty.
 */
export function sanitizeOutboundMessages(
  messages: ChatMessage[],
  keepAssistantId?: string,
): ChatMessage[] {
  const filtered = messages
    .map((m) => {
      // Assistant messages must not carry image/video media content parts. In the OpenAI-compatible
      // protocol image_url may only appear on the user role. AI-generated images stored on an assistant
      // message get rejected by upstreams such as Qwen ("incorrect modal `image` placed in the wrong
      // position, e.g. in assistant"). After switching to a text model such history images cause an
      // upstream 400, so outbound normalization strips media attachments from assistant messages. If
      // stripping leaves neither text nor attachments, the hasContent filter below removes the message.
      if (m.role !== 'assistant' || !m.attachments?.length) return m;
      const kept = m.attachments.filter((a) => a.kind !== 'image' && a.kind !== 'video');
      return { ...m, attachments: kept.length > 0 ? kept : undefined };
    })
    .filter((m) => {
      const hasContent = (m.text?.trim().length ?? 0) > 0 || (m.attachments?.length ?? 0) > 0;
      if (!hasContent) return false;
      // Keep every user message, the explicit continue/retry target (keepAssistantId), and all
      // non-failed history with content. Only failed turns are dropped: a failed exchange is not
      // context, and its empty placeholder gets filled with an error string on some clients, which
      // would be resent as a fake answer every turn. Retrying a failure revives its prefill through
      // keepAssistantId.
      return m.role === 'user' || m.id === keepAssistantId || m.state !== 'failed';
    });

  const merged: ChatMessage[] = [];
  for (const m of filtered) {
    const last = merged[merged.length - 1];
    if (last && last.role === m.role) {
      if (m.role === 'user') {
        // Two adjacent user messages can only come from the assistant between them being dropped (the
        // previous answer failed, was interrupted with an empty partial, or was an image-only reply that
        // became empty after stripping). Drop the earlier one and keep the latest: this restores strict
        // user/assistant alternation and avoids merging two independent questions into one prompt.
        merged[merged.length - 1] = m;
      } else {
        // Two consecutive turns from the same role: concatenate rather than drop, so nothing the
        // user wrote is lost on the way to a strictly alternating history.
        const joinedText = [last.text?.trim(), m.text?.trim()]
          .filter((t): t is string => !!t && t.length > 0)
          .join('\n\n');
        const joinedAttachments = [...(last.attachments ?? []), ...(m.attachments ?? [])];
        merged[merged.length - 1] = {
          ...last,
          text: joinedText,
          attachments: joinedAttachments.length > 0 ? joinedAttachments : undefined,
        };
      }
    } else {
      merged.push(m);
    }
  }
  return merged;
}

/**
 * Skipped-attachment info from buildChatHistory, for telemetry.
 * Callers receive it through the extension parameter.
 */
export { resolveWrapperVersion };

/**
 * Streaming read loop: consume the SSE stream and accumulate the result.
 *
 * Per the provider capability spec, a strategy emits `citations` events carrying a snapshot between
 * chunks. Only the latest snapshot is kept here (the strategy layer already deduped and accumulated
 * it) and returned when the stream ends.
 *
 * @param appendChunk caller-supplied rAF batching callback
 */
export async function readStream(
  stream: ReadableStream<StreamEvent>,
  initialText: string,
  appendChunk: (chunk: string) => void,
  onCitations?: (citations: Citation[]) => void,
  onReasoningChunk?: (chunk: string) => void,
  onManagedSequence?: (sequence: number) => void,
  onContinuation?: (continuation: ContinuationIntent) => void,
  /** Observes only normalized events emitted by the selected production parser. */
  onEvent?: (event: StreamEvent) => void,
): Promise<{ fullText: string; reasoningText: string; usage: OpenRouterUsage | undefined; imageAttachments: Attachment[]; servedModelID?: string; citations?: Citation[]; toolCalls: CompletedToolCall[] }> {
  const reader = stream.getReader();
  let fullText = initialText;
  let reasoningText = '';
  let usage: OpenRouterUsage | undefined;
  let servedModelID: string | undefined;
  let citations: Citation[] | undefined;
  const imageAttachments: Attachment[] = [];
  const toolCalls: ToolCallAccumulator = new Map();

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;

    const event: StreamEvent = value;
    onEvent?.(event);
    switch (event.type) {
      case 'delta':
        fullText += event.content;
        // Advance the managed delivered cursor before appendChunk: appendChunk may synchronously
        // trigger a persistence write, and that write must already count this delta's sequence as
        // delivered so the invariant "persisted sequence is a subset of persisted text" holds.
        if (event.managedSequence != null) onManagedSequence?.(event.managedSequence);
        appendChunk(event.content);
        break;
      case 'reasoning':
        // Empty strings must be passed through to onReasoningChunk: during long thinking the upstream
        // only sends `reasoning_content: ""` heartbeats (the first non-empty reasoning has been measured
        // at 279s), which are the sole "still thinking" signal, and swallowing them means minutes of no
        // feedback. Accumulated text and the managed cursor, however, only accept non-empty content: an
        // empty heartbeat carries nothing billable, and advancing the cursor would break the
        // "persisted sequence is a subset of persisted text" invariant.
        if (event.content) {
          reasoningText += event.content;
          if (event.managedSequence != null) onManagedSequence?.(event.managedSequence);
        }
        onReasoningChunk?.(event.content);
        break;
      case 'image': {
        const isDataUrl = event.url.startsWith('data:');
        const mime = isDataUrl ? (event.url.split(';')[0].split(':')[1] || 'image/png') : 'image/png';
        const b64 = isDataUrl ? (event.url.split(',')[1] || '') : event.url;
        imageAttachments.push({
          id: createCanonicalUUID(),
          kind: 'image',
          fileName: 'generated.png',
          mimeType: mime,
          base64Data: b64,
        });
        break;
      }
      case 'model':
        servedModelID = event.modelID;
        break;
      case 'usage':
        usage = event.usage;
        break;
      case 'citations':
        // The strategy already deduped and accumulated in arrival order, so overwrite the snapshot.
        citations = event.citations;
        onCitations?.(event.citations);
        break;
      case 'continuation':
        onContinuation?.(event.continuation);
        break;
      case 'tool_calls':
        mergeToolCallDeltas(toolCalls, event.toolCalls);
        break;
      case 'tool_call':
      case 'tool_result':
      case 'confirm_required':
        break;
      case 'error':
        throw {
          kind: event.errorKind || 'upstream',
          title: '',
          message: event.error,
          detail: event.errorDetail,
          i18nKey: event.i18nKey,
          retryable: event.retryable,
          source: event.source,
          status: event.status,
          upstreamURL: event.upstreamURL,
          quotaSource: event.quotaSource,
          nextAction: event.nextAction,
          severity: event.severity,
          managedErrorCode: event.managedErrorCode,
          managedErrorAction: event.managedErrorAction,
          managedErrorReasonCode: event.managedErrorReasonCode,
          managedErrorRiskRef: event.managedErrorRiskRef,
          managedErrorRetryAfterSeconds: event.managedErrorRetryAfterSeconds,
          traceId: event.traceId,
        } as ProviderError;
      case 'done':
        break;
    }
  }

  return {
    fullText,
    reasoningText,
    usage,
    imageAttachments,
    servedModelID,
    citations,
    toolCalls: finalizeToolCalls(toolCalls, 'chat_tool_call'),
  };
}

/**
 * Map a ProviderError kind to an i18n key.
 */
export function mapErrorKindKey(kind: string | undefined): string {
  const k = kind || 'upstream';
  if (
    k === 'invalidKey' || k === 'rateLimited' || k === 'network' || k === 'upstream'
    // badRequest (attachment over limit, context too long, and so on) has its own copy. Leaving it out
    // of the allowlist makes it fall back to the upstream bucket, showing "provider failure, try again"
    // for a request that is simply invalid, which makes users retry forever.
    || k === 'badRequest'
    // Without these entries the four kinds fall into the redirects below (quotaExceeded to rateLimited,
    // unauthorized to requestFailed, unavailable to upstream) and none of their translations ever
    // render: an exhausted quota shows as "rate limit exceeded" and makes users retry, and a retired
    // model shows as "provider failure". Each has its own copy, so pass the key through.
    || k === 'quotaExceeded' || k === 'unauthorized' || k === 'unavailable'
    // Custom request fields fail closed: the request never left the device (the local JSON was rejected
    // at compile time). Falling back to the upstream bucket would show "provider failure, try again",
    // and retrying a hundred times gives the same result while the real fix goes unmentioned.
    || k === 'customRequestFieldsRejected'
    // The four Grok subscription login failures need opposite user actions (adapt on our side, upgrade
    // the tier, re-authorize, or wait for the next cycle), so folding them into an existing kind points
    // users at the wrong fix.
    || k.startsWith('grokSubscription')
    // Codex subscription is the same. All four kinds are listed in RENDER_LOCALIZABLE_ERROR_KINDS and
    // all four strings exist in en.json, so the startsWith entry has to be here too, otherwise the four
    // failures get swallowed into the upstream "provider failure" bucket. Keep this in sync with the
    // grokSubscription line above.
    || k.startsWith('openAISubscription')
  ) {
    return k;
  }
  if (k === 'moderation') return 'moderationBlocked';
  return 'upstream';
}

/**
 * Allowlist of kinds whose semantics are known to live in the `errors.*` copy tree.
 * Kinds outside it (library `library_*`, proxy-layer `rate_limited`/`unknown`, and future additions)
 * must not use the upstream fallback in mapErrorKindKey, which would render "the library needs to be
 * re-authorized" as "provider failure".
 */
const RENDER_LOCALIZABLE_ERROR_KINDS = new Set<string>([
  'invalidKey', 'unauthorized', 'badRequest', 'quotaExceeded', 'rateLimited',
  'unavailable', 'network', 'upstream', 'emptyResponse', 'emptyModelCatalog',
  'moderation', 'customRequestFieldsRejected',
  'grokSubscriptionUnavailable', 'grokSubscriptionIneligible',
  'grokSubscriptionExpired', 'grokSubscriptionQuotaExhausted',
  'openAISubscriptionUnavailable', 'openAISubscriptionIneligible',
  'openAISubscriptionExpired', 'openAISubscriptionQuotaExhausted',
]);

/**
 * Copy key for a failed message, resolved at render time.
 *
 * errorTitle/errorDetail persist the localized text as it read at failure time, so after a language
 * switch they stay stuck in the old language (a Chinese UI showing an English card). Only the semantic
 * identifier is persisted; the text is resolved at render time from the kind.
 *
 * Returns null when the message's semantics cannot be mapped into `errors.*`, in which case the caller
 * must fall back to the persisted string.
 */
export function resolveErrorCopyKey(kind: string | undefined): string | null {
  if (!kind) return null;
  if (!RENDER_LOCALIZABLE_ERROR_KINDS.has(kind)) return null;
  return mapErrorKindKey(kind);
}
