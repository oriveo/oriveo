/** Convert the explicitly selected Gemini Interactions wire into the chat SSE contract. */
export function adaptGeminiInteractionsResponse(upstream: Response): Response {
  const encoder = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      const emit = (value: unknown) => controller.enqueue(encoder.encode(`data: ${JSON.stringify(value)}\n\n`));
      try {
        const contentType = upstream.headers.get('Content-Type') ?? '';
        if (contentType.includes('text/event-stream') && upstream.body) {
          await consumeSse(upstream.body, emit);
        } else {
          const json: unknown = await upstream.json().catch(() => null);
          emitContinuation(json, emit);
          for (const text of completedTexts(json)) emit({ choices: [{ delta: { content: text } }] });
          const cited = mergeUrlCitations([], completedAnnotations(json)); if (cited) emit({ type: 'citations', citations: cited });
          const usage = usageFrom(json); if (usage) emit({ type: 'usage', usage });
        }
      } catch (error) {
        emit({ type: 'error', error: error instanceof Error ? error.message : 'Gemini Interactions response failed', errorKind: 'upstream', source: 'provider' });
      }
      controller.enqueue(encoder.encode('data: [DONE]\n\n')); controller.close();
    },
  });
  return new Response(stream, { headers: { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' } });
}

function interactionErrorFrame(event: unknown): { message: string; code?: string } | null {
  if (!event || typeof event !== 'object') return null;
  const error = (event as { error?: unknown }).error;
  if (!error || typeof error !== 'object') return null;
  const { message, code, status } = error as { message?: unknown; code?: unknown; status?: unknown };
  const typeOrCode = typeof status === 'string' ? status : typeof code === 'string' ? code : undefined;
  return { message: typeof message === 'string' && message ? message : 'Gemini Interactions error', ...(typeOrCode ? { code: typeOrCode } : {}) };
}

async function consumeSse(body: ReadableStream<Uint8Array>, emit: (value: unknown) => void) {
  const reader = body.getReader(); const decoder = new TextDecoder(); let buffer = '';
  const citations: InteractionCitation[] = [];
  while (true) {
    const { done, value } = await reader.read(); if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const frames = buffer.split(/\n\n/); buffer = frames.pop() ?? '';
    for (const frame of frames) {
      const data = frame.split('\n').filter((line) => line.startsWith('data:')).map((line) => line.slice(5).trim()).join('\n');
      if (!data || data === '[DONE]') continue;
      let event: unknown; try { event = JSON.parse(data); } catch { continue; }
      // Rewrite the upstream error event into an OpenAI-style top-level error frame so the client parser recognizes it uniformly as an in-stream error frame.
      const upstreamError = interactionErrorFrame(event);
      if (upstreamError) { emit({ error: upstreamError }); continue; }
      emitContinuation(event, emit);
      for (const text of deltaTexts(event)) emit({ choices: [{ delta: { content: text } }] });
      // Only two things confirm web search ran: the search tool returned a result, or the text carries a url_citation.
      if (searchResultObserved(event)) emit({ type: 'tool_result', tool: 'google_search', summary: 'google_search', step: 1 });
      const cited = mergeUrlCitations(citations, deltaAnnotations(event)); if (cited) emit({ type: 'citations', citations: cited });
      const usage = usageFrom(event); if (usage) emit({ type: 'usage', usage });
    }
  }
}

interface InteractionCitation { url: string; title?: string }

function stepDelta(value: unknown): Record<string, any> | null {
  return isRecord(value) && value.event_type === 'step.delta' && isRecord(value.delta) ? value.delta : null;
}
/** A `google_search_result` counts as an executed search only when `result` is non-empty and not flagged `is_error`. */
function searchResultObserved(value: unknown): boolean {
  const delta = stepDelta(value);
  return delta != null && delta.type === 'google_search_result' && Array.isArray(delta.result) && delta.result.length > 0 && delta.is_error !== true;
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
function emitContinuation(value: unknown, emit: (value: unknown) => void) {
  if (!isRecord(value)) return;
  const interaction = isRecord(value.interaction) ? value.interaction : value;
  if (interaction.status !== 'completed' && value.event_type !== 'interaction.completed') return;
  if (typeof interaction.id !== 'string' || !interaction.id) return;
  emit({ type: 'continuation', continuation: { kind: 'previous_id', step: 1, state: { previousResponseId: interaction.id } } });
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
function usageFrom(value: unknown): Record<string, number> | null {
  if (!isRecord(value)) return null;
  const interaction = isRecord(value.interaction) ? value.interaction : value;
  if (!isRecord(interaction.usage)) return null;
  const raw = interaction.usage; const prompt = number(raw.total_input_tokens); const completion = number(raw.total_output_tokens);
  if (prompt == null && completion == null) return null;
  return { prompt_tokens: prompt ?? 0, completion_tokens: completion ?? 0, total_tokens: number(raw.total_tokens) ?? (prompt ?? 0) + (completion ?? 0), cached_tokens: number(raw.total_cached_tokens) ?? 0 };
}
function number(value: unknown): number | null { return typeof value === 'number' && Number.isFinite(value) ? value : null; }
function isRecord(value: unknown): value is Record<string, any> { return typeof value === 'object' && value != null && !Array.isArray(value); }
