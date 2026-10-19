import { GEMINI_INTERACTION_STATUS_KEY } from '../../context/stream-finish';

/**
 * Convert the explicitly selected Gemini Interactions wire into the chat SSE contract.
 *
 * Terminal states: completed / incomplete end with `[DONE]` (incomplete shares the ending of a
 * max_tokens truncation, and content already received is kept). An error frame, or status=failed /
 * requires_action, is rewritten into an OpenAI-style error frame with no `[DONE]` appended (no content
 * before it = an upstream error; content already received = the message failed and keeps that content).
 * status=cancelled (interaction_cancelled), or a stream that ends with neither completed nor error
 * (interaction_stream_closed), is handled as an error: the same error-frame mechanism, no `[DONE]`,
 * and no separate interruption signal. interaction_stream_closed gets StreamFinish(gemini_interactions,
 * eof_without_marker) attached by proxy-chunk-parser, with stopReason recorded as incomplete (aligned across platforms).
 * The five terminal states (completed / incomplete / requires_action / failed / cancelled) carry interaction_status
 * on the frame, which StreamFinishTracker recognizes as StreamFinish(gemini_interactions, clean, finishRaw = status).
 * Continuation output (previous_interaction_id replay) is gone.
 */
export function adaptGeminiInteractionsResponse(upstream: Response): Response {
  const encoder = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      const emit = (value: unknown) => controller.enqueue(encoder.encode(`data: ${JSON.stringify(value)}\n\n`));
      let terminal: Terminal = 'interrupted';
      try {
        const contentType = upstream.headers.get('Content-Type') ?? '';
        if (contentType.includes('text/event-stream') && upstream.body) {
          terminal = await consumeSse(upstream.body, emit);
        } else {
          const json: unknown = await upstream.json().catch(() => null);
          const upstreamError = interactionErrorFrame(json);
          if (upstreamError) {
            emit({ error: upstreamError });
            terminal = 'error';
          } else {
            for (const text of completedTexts(json)) emit({ choices: [{ delta: { content: text } }] });
            const cited = mergeUrlCitations([], completedAnnotations(json)); if (cited) emit({ type: 'citations', citations: cited });
            terminal = terminalFromInteraction(json, emit);
          }
        }
      } catch (error) {
        emit({ type: 'error', error: error instanceof Error ? error.message : 'Gemini Interactions response failed', errorKind: 'upstream', source: 'provider' });
        terminal = 'error';
      }
      if (terminal === 'interrupted') emit({ error: { message: 'Gemini Interactions stream closed before completion', code: 'interaction_stream_closed' } });
      if (terminal === 'completed' || terminal === 'incomplete') controller.enqueue(encoder.encode('data: [DONE]\n\n'));
      controller.close();
    },
  });
  return new Response(stream, { headers: { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' } });
}

type Terminal = 'completed' | 'incomplete' | 'error' | 'interrupted';

function interactionErrorFrame(event: unknown): { message: string; code?: string } | null {
  if (!event || typeof event !== 'object') return null;
  const error = (event as { error?: unknown }).error;
  if (!error || typeof error !== 'object') return null;
  const { message, code, status } = error as { message?: unknown; code?: unknown; status?: unknown };
  const typeOrCode = typeof status === 'string' ? status : typeof code === 'string' ? code : undefined;
  return { message: typeof message === 'string' && message ? message : 'Gemini Interactions error', ...(typeOrCode ? { code: typeOrCode } : {}) };
}

/** Status of interaction.completed (or a non-streaming whole body) to terminal state; failed / requires_action write an error frame on the spot. */
function terminalFromInteraction(value: unknown, emit: (value: unknown) => void): Terminal {
  if (!isRecord(value)) return 'interrupted';
  const interaction = isRecord(value.interaction) ? value.interaction : value;
  const status = interaction.status;
  if (status === 'failed' || status === 'requires_action' || status === 'cancelled') {
    // This line sends no client tools, so requires_action can only be a failure; cancelled is handled as an error.
    // The terminal status rides on the same error frame, so the client parser can attach StreamFinish(gemini_interactions) to the error event.
    const code = status === 'failed' ? 'interaction_failed' : status === 'cancelled' ? 'interaction_cancelled' : 'interaction_requires_action';
    emit({ error: { message: status === 'cancelled' ? 'Gemini Interactions cancelled' : 'Gemini Interactions error', code }, [GEMINI_INTERACTION_STATUS_KEY]: status });
    return 'error';
  }
  if (status !== 'completed' && status !== 'incomplete') return 'interrupted';
  const usage = usageFrom(interaction); if (usage) emit({ type: 'usage', usage });
  emit({ [GEMINI_INTERACTION_STATUS_KEY]: status });
  return status;
}

async function consumeSse(body: ReadableStream<Uint8Array>, emit: (value: unknown) => void): Promise<Terminal> {
  const reader = body.getReader(); const decoder = new TextDecoder(); let buffer = '';
  const citations: InteractionCitation[] = [];
  const handle = (frame: string): Terminal | null => {
    const data = frame.split('\n').filter((line) => line.startsWith('data:')).map((line) => line.slice(5).trim()).join('\n');
    if (!data || data === '[DONE]') return null;
    let event: unknown; try { event = JSON.parse(data); } catch { return null; }
    // Rewrite the upstream error event into an OpenAI-style top-level error frame so the client parser recognizes it uniformly as an in-stream error frame.
    const upstreamError = interactionErrorFrame(event);
    if (upstreamError) { emit({ error: upstreamError }); return 'error'; }
    if (isRecord(event) && event.event_type === 'interaction.completed') return terminalFromInteraction(event, emit);
    for (const text of deltaTexts(event)) emit({ choices: [{ delta: { content: text } }] });
    const thought = thoughtSummary(event); if (thought) emit({ type: 'reasoning', content: thought });
    // Only two things confirm web search ran: the search tool actually executed (google_search_result not flagged is_error), or the text carries a url_citation.
    if (searchResultObserved(event)) emit({ type: 'tool_result', tool: 'google_search', summary: 'google_search', step: 1 });
    const cited = mergeUrlCitations(citations, deltaAnnotations(event)); if (cited) emit({ type: 'citations', citations: cited });
    return null;
  };
  while (true) {
    const { done, value } = await reader.read();
    if (!done) buffer += decoder.decode(value, { stream: true });
    const frames = buffer.split(/\n\n/); buffer = done ? '' : frames.pop() ?? '';
    for (const frame of frames) {
      const terminal = handle(frame);
      if (terminal) { if (!done) await reader.cancel().catch(() => undefined); return terminal; }
    }
    if (done) return 'interrupted';
  }
}

interface InteractionCitation { url: string; title?: string }

function stepDelta(value: unknown): Record<string, any> | null {
  return isRecord(value) && value.event_type === 'step.delta' && isRecord(value.delta) ? value.delta : null;
}
/** A `google_search_result` not flagged `is_error` counts as an executed search; the official stream sample carries no `result`, so it must not be required. */
function searchResultObserved(value: unknown): boolean {
  const delta = stepDelta(value);
  return delta != null && delta.type === 'google_search_result' && delta.is_error !== true;
}
/** The thinking summary of a `thought_summary` is in `content.text`. */
function thoughtSummary(value: unknown): string {
  const delta = stepDelta(value);
  if (delta == null || delta.type !== 'thought_summary') return '';
  return textValues(isRecord(delta.content) ? [delta.content] : delta.content).join('');
}
function deltaAnnotations(value: unknown): unknown[] {
  const delta = stepDelta(value);
  return delta != null && delta.type === 'text_annotation_delta' && Array.isArray(delta.annotations) ? delta.annotations : [];
}
function completedAnnotations(value: unknown): unknown[] {
  if (!isRecord(value)) return [];
  const steps = Array.isArray(value.steps) ? value.steps : [];
  return steps.flatMap((step) => isRecord(step) && step.type === 'model_output' && Array.isArray(step.content)
    ? step.content.flatMap((part: unknown) => isRecord(part) && Array.isArray(part.annotations) ? part.annotations : [])
    : []);
}
/** Merges url_citations into the running list (deduplicated by link); returns the full snapshot only when something was added, otherwise null. */
function mergeUrlCitations(existing: InteractionCitation[], annotations: unknown[]): InteractionCitation[] | null {
  let changed = false;
  for (const annotation of annotations) {
    if (!isRecord(annotation) || annotation.type !== 'url_citation' || typeof annotation.url !== 'string' || !annotation.url.trim()) continue;
    if (existing.some((citation) => citation.url === annotation.url)) continue;
    existing.push({ url: annotation.url, ...(typeof annotation.title === 'string' && annotation.title ? { title: annotation.title } : {}) });
    changed = true;
  }
  return changed ? existing.slice() : null;
}
function deltaTexts(value: unknown): string[] {
  if (!isRecord(value) || value.event_type !== 'step.delta' || !isRecord(value.delta) || value.delta.type !== 'text') return [];
  return textValues(value.delta.text);
}
function completedTexts(value: unknown): string[] {
  if (!isRecord(value)) return [];
  const steps = Array.isArray(value.steps) ? value.steps : [];
  return steps.flatMap((step) => isRecord(step) && step.type === 'model_output' ? textValues(step.content) : []);
}
function textValues(value: unknown): string[] {
  if (typeof value === 'string') return [value];
  if (!Array.isArray(value)) return [];
  return value.flatMap((part) => isRecord(part) && typeof part.text === 'string' ? [part.text] : []);
}
function usageFrom(value: unknown): Record<string, unknown> | null {
  if (!isRecord(value)) return null;
  const interaction = isRecord(value.interaction) ? value.interaction : value;
  if (!isRecord(interaction.usage)) return null;
  const raw = interaction.usage; const prompt = number(raw.total_input_tokens); const completion = number(raw.total_output_tokens);
  if (prompt == null && completion == null) return null;
  const thought = number(raw.total_thought_tokens);
  const cached = number(raw.total_cached_tokens);
  return {
    // Thought tokens are billed as output: the same basis as this client's generateContent (candidates + thoughts), with reasoning recorded as a separate detail.
    prompt_tokens: prompt ?? 0, completion_tokens: (completion ?? 0) + (thought ?? 0),
    total_tokens: number(raw.total_tokens) ?? (prompt ?? 0) + (completion ?? 0),
    // Placed under prompt_tokens_details, which the parser (OpenAI template) reads; omitted when not reported, never a 0 posing as "no cache hit".
    ...(cached != null ? { prompt_tokens_details: { cached_tokens: cached } } : {}),
    ...(thought != null ? { completion_tokens_details: { reasoning_tokens: thought } } : {}),
  };
}
function number(value: unknown): number | null { return typeof value === 'number' && Number.isFinite(value) ? value : null; }
function isRecord(value: unknown): value is Record<string, any> { return typeof value === 'object' && value != null && !Array.isArray(value); }
