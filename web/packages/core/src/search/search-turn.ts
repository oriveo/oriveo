// External web search: execution-side combined entry.
// Reference implementation: scripts/lib/search-turn.mjs, ported function by function (same names and semantics on every client).
// From route.path of resolveWebSearchState all the way to the request and presentation: pre-send planning -> one step per search -> reply wrap-up.
// The IO layer (executor, tool loop, [D] assembly, persistence, analytics sending) only acts on this module's output and never decides counts, budget, numbering, facts or error cards itself.

import {
  regenerateSearchPolicy,
  resolveSearchTurnPath,
  SEARCH_CALL_LIMITS,
  type SearchFallbackReason,
  type SearchRegenerateAction,
  type SearchTurnPath,
  type ToolCallSupport,
  type WebSearchPath,
} from './search-route';
import { resolveSearchToolHost, THINKING_TOOL_RULES, type SearchToolHost, type SearchToolHostInput } from './search-tool-host';
import {
  budgetForNextSearch,
  citationKey,
  fitWebResults,
  searchInjectionBudget,
  summarizeSearchFacts,
  type CitationBatch,
  type CitationItem,
  type SearchFacts,
  type SearchInjectionBudget,
  type WebResultInput,
} from './search-inject';
import { searchErrorCard, TOOL_MESSAGES, type ErrorCard, type ToolMessageKey } from './search-transport';

// Criteria for upstream rejecting tools: first leg of this reply, web_search was included, the catalog does not confirm tool-call support, HTTP 400 / 422
export const TOOLS_REJECTED_STATUSES: readonly number[] = Object.freeze([400, 422]);

// Pre-search has no tools, so the text returned to the model must not mention web_search (placed where <oriveo-web> goes in [D])
export const PRESEARCH_MESSAGES: Readonly<Record<ToolMessageKey, string>> = Object.freeze({
  no_results: 'A web search for this message returned no results. Answer from what you know and say that the search found nothing.',
  unavailable: 'Web search was not available for this message. Answer directly and tell the user you could not search the web.',
  cap_reached: 'No web results could be added for this message. Answer from what you know.',
});

export interface WebSearchToolDefinition {
  name: 'web_search';
  description: string;
  parameters: {
    type: 'object';
    properties: Record<string, { type: string; description: string }>;
    required: string[];
  };
}

// web_search tool definition (visible to the model, English, byte-identical on every client; {today} = local date YYYY-MM-DD)
export const WEB_SEARCH_TOOL: Readonly<WebSearchToolDefinition> = Object.freeze<WebSearchToolDefinition>({
  name: 'web_search',
  description:
    'Search the web for current information. Today is {today}. Each result has a publication date (date) when known; the search itself happens now. For technical topics you may search once more in English. Cite results as [n] using their id; do not write a reference list. At most 3 searches per reply.',
  parameters: {
    type: 'object',
    properties: {
      query: { type: 'string', description: 'Search query, at most 400 characters.' },
      count: { type: 'integer', description: 'Number of results, 1 to 10. Default 5.' },
    },
    required: ['query'],
  },
});

// Once the remaining injection budget of this reply drops below this value no more requests are sent: the envelope skeleton plus one result no longer fits, so sending would only be billed for nothing
export const MIN_SEARCH_BUDGET_TOKENS = 256;

export const RESULT_BUCKETS = Object.freeze(['0', '1-3', '4-5', '6-10'] as const);
export const LATENCY_BUCKETS = Object.freeze(['lt_1s', '1_3s', '3_10s', 'gte_10s'] as const);

const resultBucket = (n: number) => (n <= 0 ? '0' : n <= 3 ? '1-3' : n <= 5 ? '4-5' : '6-10');
const latencyBucket = (ms: number) => (ms < 1000 ? 'lt_1s' : ms < 3000 ? '1_3s' : ms < 10000 ? '3_10s' : 'gte_10s');
const EXTERNAL = new Set<string>(['external_tool', 'external_presearch']);

export interface SearchService {
  id: string;
  name: string;
  protocol: string;
  custom?: boolean;
}

export interface SearchTelemetry {
  event: string;
  props: Record<string, string | boolean>;
}

export interface PlanSearchTurnInput {
  path: WebSearchPath;
  service?: SearchService | null;
  toolCall?: ToolCallSupport;
  host?: Omit<SearchToolHostInput, 'path'>;
  thinking?: { on?: boolean; protocol?: string; continuationStateAvailable?: boolean };
  upstreamRejection?: { status: number; leg: number } | null;
  /** This conversation x model was already rejected once in this run (kept in memory only, not persisted) */
  toolsRejectedBefore?: boolean;
  regenerate?: { action: SearchRegenerateAction; previousResultsPersisted: boolean };
  userText?: string;
  B?: number | null;
  today?: string;
}

export interface SearchTurnPlan extends SearchTurnPath {
  toolHost: SearchToolHost;
  webSearchTool: WebSearchToolDefinition | null;
  presearch: { query: string; count: number } | null;
  reuse: boolean;
  budget: SearchInjectionBudget | null;
  writeToolConfirm: 'once_when_web_results_present' | 'n/a';
  telemetry: SearchTelemetry[];
}

/** Pre-send planning (called once per send, and once more after upstream rejects tools and the route switches). */
export function planSearchTurn(input: PlanSearchTurnInput): SearchTurnPlan {
  const host = input.host ?? {};
  if (!EXTERNAL.has(input.path)) {
    const turn = resolveSearchTurnPath({ path: input.path });
    return {
      ...turn,
      toolHost: resolveSearchToolHost({ ...host, path: input.path }),
      webSearchTool: null,
      presearch: null,
      reuse: false,
      budget: null,
      writeToolConfirm: 'n/a',
      telemetry: [],
    };
  }
  if (!input.service) throw new Error('external path without service');
  const thinking = input.thinking ?? {};
  const toolHost = input.path === 'external_tool' ? resolveSearchToolHost({ ...host, path: 'external_tool' }) : null;
  const rej = input.upstreamRejection;
  const rejectedNow = rej != null && rej.leg === 0 && TOOLS_REJECTED_STATUSES.includes(rej.status) && input.toolCall !== 'supported';
  // This conversation x model was already rejected once in this run: go straight to pre-search without notifying again
  const rejectedBefore = input.toolsRejectedBefore === true && input.toolCall !== 'supported';
  const upstreamRejectedTools = rejectedNow || rejectedBefore;
  const rule = thinking.protocol !== undefined && Object.prototype.hasOwnProperty.call(THINKING_TOOL_RULES, thinking.protocol) ? THINKING_TOOL_RULES[thinking.protocol] : undefined;
  const turn = resolveSearchTurnPath({
    path: input.path,
    thinkingOn: thinking.on === true,
    // A protocol that has not been verified always uses pre-search when thinking is on
    thinkingWithTools: rule?.thinkingWithTools ?? 'presearch',
    continuationStateAvailable: thinking.continuationStateAvailable !== false,
    upstreamRejectedTools,
    hostMaxSteps: toolHost && toolHost.webSearchRegistered ? toolHost.maxSteps : 0,
  });
  const regen = regenerateSearchPolicy(input.regenerate ?? { action: 'send', previousResultsPersisted: false });
  const reuse = regen.reusePrevious === true;
  const toolPath = turn.path === 'external_tool' && !reuse;
  return {
    ...turn,
    noticeOnce: turn.noticeOnce && rejectedNow,
    requestHasWebSearchTool: toolPath,
    toolHost: toolPath && toolHost ? toolHost : resolveSearchToolHost({ ...host, path: 'external_presearch' }),
    webSearchTool: toolPath ? { ...WEB_SEARCH_TOOL, description: WEB_SEARCH_TOOL.description.replace('{today}', input.today ?? '') } : null,
    presearch: turn.path === 'external_presearch' && !reuse ? { query: input.userText ?? '', count: 5 } : null,
    reuse,
    budget: searchInjectionBudget(input.B),
    // When web results enter the context this turn, MCP write tools are forced to "this time only"; this applies to pre-search as well
    writeToolConfirm: host.mcp === true ? 'once_when_web_results_present' : 'n/a',
    telemetry: turn.fallbackReason ? [{ event: 'search_fallback_presearch', props: { reason: turn.fallbackReason } }] : [],
  };
}

export interface SearchCitation {
  number: number;
  source: 'external_search';
  title: string;
  url: string;
  snippet: string;
  query: string;
  serviceId: string;
  serviceName: string;
  retrievedAt: string;
  site?: string;
  date?: string;
}

export interface SearchCallRecord {
  query: string;
  outcome: string;
  delivered: number;
  requests: number;
  errorClass: string | null;
  reused?: boolean;
}

interface InFlightCall {
  query: string;
  count?: number | null;
  requests: number;
  attempts: number;
  latencyMs: number;
  reused?: boolean;
}

export interface OtherSearchService {
  id: string;
  name: string;
  isDefault?: boolean;
}

export interface SearchReplyState {
  path: 'presearch' | 'tool';
  notice: SearchFallbackReason | null;
  service: SearchService;
  otherServices: OtherSearchService[];
  B: number | null;
  rhoHi: number;
  retrievedAt: string;
  requestsSent: number;
  usedTokens: number;
  allocator: { keys: Record<string, number>; next: number };
  current: InFlightCall | null;
  calls: SearchCallRecord[];
  citations: SearchCitation[];
  webResultsPresent: boolean;
}

export interface StartSearchReplyInput {
  plan: Pick<SearchTurnPlan, 'path' | 'fallbackReason' | 'noticeOnce'>;
  service: SearchService;
  otherServices?: OtherSearchService[];
  B?: number | null;
  rhoHi: number;
  retrievedAt: string;
  /** Sources already numbered before the search in this message (library <entry citation>), sharing one allocator with external search */
  priorBatches?: readonly CitationBatch[];
}

/** Search state of one reply. */
export function startSearchReply(input: StartSearchReplyInput): SearchReplyState {
  const keys: Record<string, number> = {};
  let next = 1;
  for (const batch of input.priorBatches ?? []) {
    for (const item of batch.items) {
      const k = citationKey(item);
      if (!(k in keys)) keys[k] = next++;
    }
  }
  return {
    path: input.plan.path === 'external_presearch' ? 'presearch' : 'tool',
    notice: input.plan.noticeOnce ? input.plan.fallbackReason : null,
    service: input.service,
    otherServices: input.otherServices ?? [],
    B: input.B ?? null,
    rhoHi: input.rhoHi,
    retrievedAt: input.retrievedAt,
    requestsSent: 0,
    usedTokens: 0,
    allocator: { keys, next },
    current: null,
    calls: [],
    citations: [],
    webResultsPresent: false,
  };
}

export type SearchOutcome =
  | { results: readonly WebResultInput[]; latencyMs?: number; empty?: undefined; error?: undefined }
  | { empty: true; latencyMs?: number; results?: undefined; error?: undefined }
  | { error: { errorClass: string; retryOnce?: boolean }; sent?: boolean; latencyMs?: number; results?: undefined; empty?: undefined };

export type SearchEvent =
  | { type: 'call'; query?: string | null; count?: number | null }
  | { type: 'result'; outcome: SearchOutcome }
  | { type: 'reuse'; query: string; results: readonly WebResultInput[] }
  | { type: 'other_sources'; source: string; items: readonly CitationItem[] }
  | { type: 'stopped' };

export type SearchEffect =
  | { kind: 'send'; retry: boolean; activity: { kind: 'external_search'; serviceName: string; query: string } }
  | { kind: 'deliver'; content: string; citations: SearchCitation[]; webResultsPresent: boolean; telemetry: SearchTelemetry[] }
  | { kind: 'numbers'; numbers: number[] }
  | { kind: 'none' };

export interface SearchStep {
  state: SearchReplyState;
  effect: SearchEffect;
}

const messages = (state: SearchReplyState) => (state.path === 'presearch' ? PRESEARCH_MESSAGES : TOOL_MESSAGES);

function deliverResults(state: SearchReplyState, query: string, results: readonly WebResultInput[]) {
  // URLs already numbered in this message are not given to the model again (they are already in context); only new results are numbered
  const fresh: WebResultInput[] = [];
  const seen = new Set<string>();
  for (const r of results) {
    const k = citationKey({ url: r.url });
    if (k in state.allocator.keys || seen.has(k)) continue;
    seen.add(k);
    fresh.push(r);
  }
  const budgetTokens = budgetForNextSearch({ B: state.B, usedTokens: state.usedTokens });
  const fit = fresh.length
    ? fitWebResults({ provider: state.service.name, query, retrievedAt: state.retrievedAt, results: fresh, firstId: state.allocator.next, budgetTokens, rhoHi: state.rhoHi })
    : null;
  if (!fit || !fit.envelope) {
    return { state, delivered: 0, content: messages(state)[fresh.length ? 'cap_reached' : 'no_results'], citations: [] as SearchCitation[] };
  }
  const keys = { ...state.allocator.keys };
  const citations = fit.ids.map((id, i) => {
    const r = fresh[i];
    keys[citationKey({ url: r.url })] = id;
    const c: SearchCitation = {
      number: id,
      source: 'external_search',
      title: r.title,
      url: r.url,
      snippet: r.snippet ?? '',
      query,
      serviceId: state.service.id,
      serviceName: state.service.name,
      retrievedAt: state.retrievedAt,
    };
    if (r.site) c.site = r.site;
    if (r.date) c.date = r.date;
    return c;
  });
  return {
    state: {
      ...state,
      usedTokens: state.usedTokens + fit.estimatedTokens,
      allocator: { keys, next: state.allocator.next + fit.ids.length },
      citations: [...state.citations, ...citations],
      webResultsPresent: true,
    },
    delivered: citations.length,
    content: fit.envelope,
    citations,
  };
}

function finishCall(state: SearchReplyState, outcome: SearchOutcome): SearchStep {
  const cur = state.current as InFlightCall;
  let s: SearchReplyState = { ...state, current: null };
  let delivered = 0;
  let content: string;
  let citations: SearchCitation[] = [];
  let recorded: string;
  if (outcome.results) {
    const r = deliverResults(s, cur.query, outcome.results);
    s = r.state;
    delivered = r.delivered;
    content = r.content;
    citations = r.citations;
    recorded = delivered > 0 ? 'results' : 'empty';
  } else if (outcome.empty) {
    content = messages(s).no_results;
    recorded = 'empty';
  } else {
    content = messages(s).unavailable;
    recorded = (outcome.error as { errorClass: string }).errorClass;
  }
  const errorClass = outcome.error ? outcome.error.errorClass : 'none';
  s = {
    ...s,
    calls: [...s.calls, { query: cur.query, outcome: recorded, delivered, requests: cur.requests, errorClass: outcome.error ? errorClass : null, reused: cur.reused === true }],
  };
  const telemetry: SearchTelemetry[] = cur.reused
    ? []
    : [
        {
          event: 'search_executed',
          props: {
            service: s.service.custom ? 'custom' : s.service.id,
            protocol: s.service.protocol,
            path: s.path,
            result_bucket: resultBucket(delivered),
            latency_bucket: latencyBucket(cur.latencyMs),
            error_class: errorClass,
            retried: cur.attempts > 1,
          },
        },
      ];
  return { state: s, effect: { kind: 'deliver', content, citations, webResultsPresent: s.webResultsPresent, telemetry } };
}

/** One step: the model calls web_search / the executor returns / resend reuse / an MCP source inside the loop / the user stops. */
export function applySearchEvent(state: SearchReplyState, event: SearchEvent): SearchStep {
  if (event.type === 'other_sources') {
    const keys = { ...state.allocator.keys };
    let next = state.allocator.next;
    const numbers = event.items.map((item) => {
      const k = citationKey(item);
      if (!(k in keys)) keys[k] = next++;
      return keys[k];
    });
    return { state: { ...state, allocator: { keys, next } }, effect: { kind: 'numbers', numbers } };
  }
  if (event.type === 'stopped') {
    if (!state.current) return { state, effect: { kind: 'none' } };
    const cur = state.current;
    // User stopped: the in-flight request was already sent, so it still counts as one search (no results)
    const s: SearchReplyState = {
      ...state,
      current: null,
      requestsSent: state.requestsSent + 1,
      calls: [...state.calls, { query: cur.query, outcome: 'empty', delivered: 0, requests: cur.requests + 1, errorClass: null }],
    };
    return { state: s, effect: { kind: 'none' } };
  }
  if (event.type === 'reuse') {
    // Resend reuse: rebuilt from the citations already persisted for that message; no request is sent
    const s: SearchReplyState = { ...state, current: { query: event.query, requests: 0, attempts: 0, latencyMs: 0, reused: true } };
    return finishCall(s, { results: event.results });
  }
  if (event.type === 'call') {
    if (state.current) throw new Error('call while another call is in flight');
    const query = (event.query ?? '').trim();
    // An empty query sends no request and does not count as a search
    if (!query) return { state, effect: { kind: 'deliver', content: messages(state).no_results, citations: [], webResultsPresent: state.webResultsPresent, telemetry: [] } };
    const noBudget = budgetForNextSearch({ B: state.B, usedTokens: state.usedTokens }) < MIN_SEARCH_BUDGET_TOKENS;
    if (state.requestsSent >= SEARCH_CALL_LIMITS.maxSearchRequestsPerReply || noBudget) {
      // Cap exceeded or this reply's injection budget used up: no request is sent and nothing is billed
      const s: SearchReplyState = { ...state, calls: [...state.calls, { query, outcome: 'cap_reached', delivered: 0, requests: 0, errorClass: null }] };
      return { state: s, effect: { kind: 'deliver', content: messages(state).cap_reached, citations: [], webResultsPresent: state.webResultsPresent, telemetry: [] } };
    }
    const s: SearchReplyState = { ...state, current: { query, count: event.count ?? null, requests: 0, attempts: 0, latencyMs: 0 } };
    return { state: s, effect: { kind: 'send', retry: false, activity: { kind: 'external_search', serviceName: state.service.name, query } } };
  }
  if (event.type === 'result') {
    if (!state.current) throw new Error('result without call');
    const o = event.outcome;
    const sent = o.error ? o.sent !== false : true;
    const cur: InFlightCall = {
      ...state.current,
      attempts: state.current.attempts + 1,
      requests: state.current.requests + (sent ? 1 : 0),
      latencyMs: state.current.latencyMs + (o.latencyMs ?? 0),
    };
    const s: SearchReplyState = { ...state, current: cur, requestsSent: state.requestsSent + (sent ? 1 : 0) };
    const canRetry =
      o.error && o.error.retryOnce === true && cur.attempts <= SEARCH_CALL_LIMITS.maxRetriesPerCall && s.requestsSent < SEARCH_CALL_LIMITS.maxSearchRequestsPerReply;
    if (canRetry) return { state: s, effect: { kind: 'send', retry: true, activity: { kind: 'external_search', serviceName: s.service.name, query: cur.query } } };
    return finishCall(s, o);
  }
  throw new Error(`unknown event type ${(event as { type?: unknown }).type}`);
}

export interface SearchSourcesLine {
  searchCount: number;
  serviceName: string;
  sourceCount: number;
  /** All from resend reuse (no new request, no new billing); the source row reads "reusing the previous search" */
  reused: boolean;
  custom: boolean;
}

export interface SearchReplyErrorCard extends ErrorCard {
  errorClass: string;
  serviceName: string;
  switchTo: { id: string; name: string } | null;
}

export interface SearchReplyFinish {
  facts: SearchFacts;
  sourcesLine: SearchSourcesLine | null;
  errorCard: SearchReplyErrorCard | null;
  notice: SearchFallbackReason | null;
  citations: SearchCitation[];
  webResultsPresent: boolean;
}

/** Reply wrap-up: message facts, source row, error card, and the sources to persist. */
export function finishSearchReply(state: SearchReplyState): SearchReplyFinish {
  const calls = state.calls.map((c) => ({ outcome: c.outcome, delivered: c.delivered }));
  const path = state.path === 'presearch' ? 'external_presearch' : 'external_tool';
  const facts = summarizeSearchFacts(
    path === 'external_presearch'
      ? { path, webOn: true, presearch: calls[0] ?? null, serviceName: state.service.name }
      : { path, webOn: true, calls, serviceName: state.service.name },
  );
  const sourcesLine =
    facts.searchCount > 0 && facts.state !== 'failed'
      ? {
          searchCount: facts.searchCount,
          serviceName: state.service.name,
          sourceCount: facts.sourceCount,
          reused: state.calls.every((c) => c.reused === true),
          custom: state.service.custom === true,
        }
      : null;
  let errorCard: SearchReplyErrorCard | null = null;
  if (facts.state === 'failed') {
    const last = [...state.calls].reverse().find((c) => c.errorClass) as SearchCallRecord & { errorClass: string };
    const card = searchErrorCard(last.errorClass, { custom: state.service.custom === true, otherServices: state.otherServices.length });
    const other = state.otherServices.find((o) => o.isDefault) ?? state.otherServices[0] ?? null;
    errorCard = {
      errorClass: last.errorClass,
      ...card,
      serviceName: state.service.name,
      switchTo: card.secondaryAction === 'switch_to_other_service' && other ? { id: other.id, name: other.name } : null,
    };
  }
  return { facts, sourcesLine, errorCard, notice: state.notice, citations: state.citations, webResultsPresent: state.webResultsPresent };
}

/**
 * Compact record of a history assistant message: derived from its persisted external_search sources, containing only the query, titles and URLs, no summaries.
 * Appended after the message body with one blank line in between; returns null when there are no external sources.
 */
export function searchedRecordLine(citations: readonly { source: string; query?: string; title: string; url: string }[] | null | undefined): string | null {
  const groups: { query: string; items: string[] }[] = [];
  const byQuery = new Map<string, { query: string; items: string[] }>();
  for (const c of citations ?? []) {
    if (c.source !== 'external_search') continue;
    const q = c.query ?? '';
    let g = byQuery.get(q);
    if (!g) {
      g = { query: q, items: [] };
      byQuery.set(q, g);
      groups.push(g);
    }
    g.items.push(`${c.title} (${c.url})`);
  }
  if (!groups.length) return null;
  return `Web searches used for this reply (titles and URLs only): ${groups.map((g) => `"${g.query}" → ${g.items.join(', ')}`).join('; ')}`;
}
