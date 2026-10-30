/**
 * Chat execution wiring for external web search (external search service contract, sections 5a / 6 / 7 / 12-15).
 *
 * The IO layer only acts on the outputs of core/search/search-turn functions: counts, budget, numbering, facts and error cards are never decided here.
 * - Planning: `planExternalSearchTurn` (state's current source service + local facts -> planSearchTurn);
 * - Execution: `createExternalSearchExecutor` (via /api/search/forward, the same forwardSearch as the settings page test search);
 * - One reply: `startExternalSearchReply` (event loop, reuse, MCP source numbering, stop, finalize persistence patch);
 * - Tool: `createWebSearchEntry` (the web_search entry of the generic ToolCallLoop; results are always neutral).
 */
import type { AIModel, Citation, ChatMessage, Provider, ReasoningMode } from '@oriveo/shared';
import type { StoreApi } from 'zustand';
import type { StreamOptions } from '@oriveo/core/providers/types';
import { effectiveMaxSteps } from '@oriveo/core/mcp/mcp-types';
import type { AppStore } from '../store/app-store';
import { currentMcpRuntimeConfig } from '../mcp/mcp-store';
import { resolveCatalogModel } from '../metadata/metadata-client';
import { trackEvent } from '../telemetry';
import { externalSearchModelKey } from '../../search/external-search-context';
import { canonicalFinalTransport } from './capability-preference-settings';
import { resolveModelCapabilityEvidence } from './capability-evidence';
import { providerControlsAreManaged } from './stream-options';
import { loadExternalSearchSendContext } from './external-search-send';
import type { ProxyToolDefinition } from '@oriveo/core/providers/request-builders/runtime';
import type { StreamActivityExternalSearch } from '@oriveo/core/providers/types';
import type { ToolRegistryEntry } from '@oriveo/core/tools/tool-loop-contracts';
import { searchServiceSelectable, type SearchRegenerateAction, type ToolCallSupport } from '@oriveo/core/search/search-route';
import type { CitationBatch, CitationItem, WebResultInput } from '@oriveo/core/search/search-inject';
import type { SearchToolHostInput } from '@oriveo/core/search/search-tool-host';
import { TOOL_MESSAGES } from '@oriveo/core/search/search-transport';
import {
  applySearchEvent,
  finishSearchReply,
  planSearchTurn,
  startSearchReply,
  type OtherSearchService,
  type SearchOutcome,
  type SearchReplyFinish,
  type SearchReplyState,
  type SearchService,
  type SearchStep,
  type SearchTelemetry,
  type SearchTurnPlan,
} from '@oriveo/core/search/search-turn';
import type { TelemetryEventName, TelemetryProperties } from '@oriveo/shared';
import { forwardSearch, searchConnectionsFromProviders, type SearchConnectionOption, type SearchForwardTarget, type SearchServiceView } from '../../search/search-settings-data';
import { readSearchServiceKey } from '../../search/search-service-store';
import { externalSearchCapabilityResult } from './capability-result-runtime';
import type { ExternalSearchSendContext } from './external-search-send';
import { applyExternalSearchActivity, clearExternalSearchActivity, externalSearchActivityView } from './external-search-activity';

// ── Planning ─────────────────────────────────────────────────────────────

export interface ExternalSearchBinding {
  /** id = local service record id (used by the source's serviceId, and by the error card's serviceId / switchTo for jumping to details, pick_service). */
  service: SearchService;
  /** Telemetry service: preset = catalog id, custom = custom (report the enum only). */
  telemetryService: string;
  view: SearchServiceView;
  otherServices: OtherSearchService[];
}

/** The state's current source service (ids are always local record ids; presets use protocol catalog, custom services use their own protocol). Not an external source = null. */
export function externalSearchBindingOf(context: ExternalSearchSendContext): ExternalSearchBinding | null {
  const { state, data } = context;
  const serviceId = state.source.serviceId;
  if (!serviceId) return null;
  const view = data.snapshot.services.find((s) => s.record.id === serviceId);
  if (!view) return null;
  const record = view.record;
  const service: SearchService = record.kind === 'preset'
    ? { id: record.id, name: view.name, protocol: 'catalog', custom: false }
    : { id: record.id, name: view.name, protocol: record.protocol, custom: true };
  const telemetryService = record.kind === 'preset' ? record.serviceId : 'custom';
  const otherServices = data.snapshot.services
    .filter((s) => s.record.id !== serviceId && searchServiceSelectable(s.row.status))
    .map((s) => ({ id: s.record.id, name: s.name, isDefault: s.record.id === data.snapshot.defaultId }));
  return { service, telemetryService, view, otherServices };
}

const THINKING_CHAT_KINDS: Readonly<Record<string, string>> = Object.freeze({
  deepseek: 'deepseek_chat',
  moonshot: 'moonshot_chat',
  zhipu: 'zhipu_chat',
  qwen: 'qwen_chat',
});

/**
 * Protocol adapter used by this turn's request -> key into the thinking-tool rule table (THINKING_TOOL_RULES). Chat completions shapes are split by official connection kind;
 * everything else is passed through as-is (absent from the table = unverified, planSearchTurn treats it as pre-search).
 */
export function searchThinkingProtocol(provider: Pick<Provider, 'kind'>, wireProtocol: string | undefined): string | undefined {
  if (wireProtocol === 'openai_chat' && THINKING_CHAT_KINDS[provider.kind]) return THINKING_CHAT_KINDS[provider.kind];
  return wireProtocol;
}

/** Remember in-process (not persisted) which "conversation x modelKey" pairs the upstream has rejected tools for. */
const toolsRejected = new Set<string>();
export function rememberToolsRejected(conversationId: string, modelKey: string): void {
  toolsRejected.add(`${conversationId}\u0000${modelKey}`);
}
export function toolsRejectedBefore(conversationId: string, modelKey: string): boolean {
  return toolsRejected.has(`${conversationId}\u0000${modelKey}`);
}
/** For tests. */
export function __resetToolsRejectedForTests(): void {
  toolsRejected.clear();
}

export interface PlanExternalSearchInput {
  toolCall: ToolCallSupport | undefined;
  host: Omit<SearchToolHostInput, 'path'>;
  thinking: { on: boolean; protocol: string | undefined; continuationStateAvailable: boolean };
  regenerate?: { action: SearchRegenerateAction; previousCitations?: readonly Citation[] | null };
  userText: string;
  B: number | null | undefined;
  upstreamRejection?: { status: number; leg: number } | null;
  toolsRejectedBefore?: boolean;
  today?: string;
}

export interface ExternalSearchTurn {
  plan: SearchTurnPlan;
  binding: ExternalSearchBinding;
}

/**
 * Planning input thinking.on: this turn's outbound request really carries reasoning parameters -- the level is set and is not 'fast', and the reasoning field was not stripped.
 * Normal sending and the library / MCP tool loops use the same check.
 */
export function searchThinkingOn(reasoningMode: ReasoningMode | undefined, reasoningExcluded = false): boolean {
  return reasoningMode !== undefined && reasoningMode !== 'fast' && !reasoningExcluded;
}

/** Planning input host.memoryTools: this turn's registry really has a memory tool entry (either propose_memory or search_memory). All send paths use the same check. */
export function hostMemoryToolsRegistered(entries: { propose: boolean; search: boolean }): boolean {
  return entries.propose || entries.search;
}

/** Local date YYYY-MM-DD (the {today} in the tool definition). */
export function localToday(now: Date = new Date()): string {
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
}

/** Pre-send planning (once per send, and once more for the reroute after upstream rejects tools). Not an external path / source service not found = null (behavior as before). */
export function planExternalSearchTurn(context: ExternalSearchSendContext | null, input: PlanExternalSearchInput): ExternalSearchTurn | null {
  if (!context) return null;
  const path = context.state.route.path;
  if (path !== 'external_tool' && path !== 'external_presearch') return null;
  const binding = externalSearchBindingOf(context);
  if (!binding) return null;
  const previous = externalSearchCitations(input.regenerate?.previousCitations);
  const plan = planSearchTurn({
    path,
    service: binding.service,
    ...(input.toolCall ? { toolCall: input.toolCall } : {}),
    host: input.host,
    thinking: {
      on: input.thinking.on,
      ...(input.thinking.protocol !== undefined ? { protocol: input.thinking.protocol } : {}),
      continuationStateAvailable: input.thinking.continuationStateAvailable,
    },
    upstreamRejection: input.upstreamRejection ?? null,
    toolsRejectedBefore: input.toolsRejectedBefore === true,
    regenerate: { action: input.regenerate?.action ?? 'send', previousResultsPersisted: previous.length > 0 },
    userText: input.userText,
    B: input.B ?? null,
    today: input.today ?? localToday(),
  });
  return { plan, binding };
}

// ── Execution ─────────────────────────────────────────────────────────────

export type ExternalSearchExecutor = (query: string, count: number | null | undefined, signal?: AbortSignal) => Promise<SearchOutcome>;

/** Executor: sends once via /api/search/forward and maps the result to the result outcome of applySearchEvent. */
export function createExternalSearchExecutor(
  binding: ExternalSearchBinding,
  deps: { uid: string; connections: readonly SearchConnectionOption[]; fetchImpl?: typeof fetch },
): ExternalSearchExecutor {
  const record = binding.view.record;
  const target: SearchForwardTarget = record.kind === 'preset'
    ? { kind: 'preset', serviceId: record.serviceId, regionId: record.regionId, boundHost: record.boundHost }
    : { kind: 'custom', address: record.address, protocol: record.protocol, mapping: record.mapping };
  return async (query, count, signal) => {
    const key = record.kind === 'preset' && record.connectionRef
      ? deps.connections.find((c) => c.id === record.connectionRef)?.apiKey ?? null
      : await readSearchServiceKey(deps.uid, record.id).catch(() => null);
    // A preset service whose key cannot be read (including a reused connection that was deleted, or an unreadable search partition) sends no request: it returns auth_invalid with sent:false, and the error card offers "Update key".
    // A custom service's key is optional, so it is sent as usual.
    if (record.kind === 'preset' && !key) {
      return { error: { errorClass: 'auth_invalid', retryOnce: false }, sent: false };
    }
    const n = typeof count === 'number' && Number.isInteger(count) && count >= 1 && count <= 10 ? count : binding.view.resultCount;
    const outcome = await forwardSearch(
      { target, key, query, count: n, otherServices: binding.otherServices.length },
      deps.fetchImpl ?? fetch,
      signal,
    );
    if (outcome.ok) {
      return outcome.results.length > 0
        ? { results: outcome.results, latencyMs: outcome.latencyMs }
        : { empty: true, latencyMs: outcome.latencyMs };
    }
    return {
      error: { errorClass: outcome.errorClass ?? 'upstream_error', retryOnce: outcome.retryOnce },
      sent: outcome.sent,
      latencyMs: outcome.latencyMs,
    };
  };
}

// ── Display context of the activity row (not persisted) ─────────────────────────────────────

/** Service name and query of the conversation's current `external_search` activity (the one being searched now; none = null). */
export function externalSearchActivityOf(conversationId: string): StreamActivityExternalSearch | null {
  const view = externalSearchActivityView(conversationId);
  const searching = view?.chips.find((chip) => chip.searching);
  return view && searching ? { serviceName: view.serviceName, query: searching.query } : null;
}
export function setExternalSearchActivity(conversationId: string, detail: StreamActivityExternalSearch | null): void {
  applyExternalSearchActivity(conversationId, detail);
}
export { clearExternalSearchActivity };

// ── One reply ─────────────────────────────────────────────────────────

export interface ExternalSearchReply {
  readonly turn: ExternalSearchTurn;
  /** One search: call -> send (including one retry) -> deliver; returns the content handed to the model (envelope or fixed text). */
  search(query: string | null | undefined, count?: number | null, signal?: AbortSignal): Promise<string>;
  /** Resend reuse: the regenerated message's external_search sources are grouped by query and sent as reuse; returns each group's content (joined with a blank line). */
  reuse(previous: readonly Citation[] | null | undefined): string;
  /**
   * Reuse for internal automatic resends within this turn (overflow recovery, etc.): rebuild the envelope on a separate state from the web sources this reply has already produced, via reuse events (numbering matches what was already produced),
   * sending no request and leaving this reply's state untouched (message facts and sources remain the real result of this turn's search). No web results = ''.
   */
  replayEnvelope(): string;
  /** MCP source numbering inside the loop. */
  otherSources(source: string, items: readonly CitationItem[]): number[];
  /** User stop: the in-flight call is still counted. */
  stop(): void;
  webResultsPresent(): boolean;
  finish(): SearchReplyFinish;
}

export interface StartExternalSearchReplyInput {
  turn: ExternalSearchTurn;
  /** The plan after rerouting (when tools are rejected, pass the recomputed one). */
  plan?: SearchTurnPlan;
  B: number | null | undefined;
  rhoHi: number;
  retrievedAt?: string;
  execute: ExternalSearchExecutor;
  priorBatches?: readonly CitationBatch[];
  onActivity?: (activity: StreamActivityExternalSearch | null) => void;
  track: (event: TelemetryEventName, props: TelemetryProperties) => void;
}

export function startExternalSearchReply(input: StartExternalSearchReplyInput): ExternalSearchReply {
  const plan = input.plan ?? input.turn.plan;
  const retrievedAt = input.retrievedAt ?? new Date().toISOString();
  const initialState = (): SearchReplyState => startSearchReply({
    plan,
    service: input.turn.binding.service,
    otherServices: input.turn.binding.otherServices,
    B: input.B ?? null,
    rhoHi: input.rhoHi,
    retrievedAt,
    ...(input.priorBatches ? { priorBatches: input.priorBatches } : {}),
  });
  let state: SearchReplyState = initialState();
  // Telemetry service reports only the catalog id / custom, never the local record id (search_executed).
  const emit = (telemetry: readonly SearchTelemetry[]) => {
    for (const t of telemetry) {
      const props = 'service' in t.props ? { ...t.props, service: input.turn.binding.telemetryService } : t.props;
      input.track(t.event as TelemetryEventName, props);
    }
  };
  const apply = (event: Parameters<typeof applySearchEvent>[1]): SearchStep => {
    const step = applySearchEvent(state, event);
    state = step.state;
    return step;
  };
  const deliverContent = (step: SearchStep): string => {
    if (step.effect.kind !== 'deliver') throw new Error(`unexpected search effect ${step.effect.kind}`);
    emit(step.effect.telemetry);
    return step.effect.content;
  };
  return {
    turn: { ...input.turn, plan },
    async search(query, count, signal) {
      let step = apply({ type: 'call', query: query ?? '', count: count ?? null });
      try {
        while (step.effect.kind === 'send') {
          input.onActivity?.({ serviceName: step.effect.activity.serviceName, query: step.effect.activity.query });
          const outcome = await input.execute(step.effect.activity.query, count, signal);
          step = apply({ type: 'result', outcome });
        }
      } finally {
        input.onActivity?.(null);
      }
      return deliverContent(step);
    },
    reuse(previous) {
      const groups = new Map<string, WebResultInput[]>();
      for (const c of externalSearchCitations(previous)) {
        const q = c.query ?? '';
        const list = groups.get(q) ?? [];
        list.push({ title: c.title ?? c.url, url: c.url, site: c.site ?? null, date: c.date ?? null, snippet: c.snippet ?? '' });
        groups.set(q, list);
      }
      const parts: string[] = [];
      for (const [query, results] of groups) parts.push(deliverContent(apply({ type: 'reuse', query, results })));
      return parts.join('\n\n');
    },
    replayEnvelope() {
      // In numbering order, adjacent calls with the same query form one group: the allocator numbers from the same start, so the rebuilt numbers match those already produced this turn one to one.
      let replay = initialState();
      const parts: string[] = [];
      let group: { query: string; results: WebResultInput[] } | null = null;
      const flush = () => {
        if (!group) return;
        const step = applySearchEvent(replay, { type: 'reuse', query: group.query, results: group.results });
        replay = step.state;
        if (step.effect.kind === 'deliver') parts.push(step.effect.content);
        group = null;
      };
      for (const c of [...state.citations].sort((a, b) => a.number - b.number)) {
        const result: WebResultInput = { title: c.title, url: c.url, site: c.site ?? null, date: c.date ?? null, snippet: c.snippet };
        if (group && group.query === c.query) group.results.push(result);
        else {
          flush();
          group = { query: c.query, results: [result] };
        }
      }
      flush();
      return parts.join('\n\n');
    },
    otherSources(source, items) {
      const step = apply({ type: 'other_sources', source, items });
      return step.effect.kind === 'numbers' ? step.effect.numbers : [];
    },
    stop() {
      apply({ type: 'stopped' });
    },
    webResultsPresent: () => state.webResultsPresent,
    finish: () => finishSearchReply(state),
  };
}

/** External search sources of the regenerated message (ordered by number). */
export function externalSearchCitations(citations: readonly Citation[] | null | undefined): Citation[] {
  return (citations ?? [])
    .filter((c) => c.source === 'external_search')
    .slice()
    .sort((a, b) => (a.index ?? 0) - (b.index ?? 0));
}

/**
 * Finalize persistence patch: sources (the same list as library / MCP sources, number written to index, summary stored in full), message facts (capability result),
 * error card (whole + serviceId), one-time hint. `existing` = the non-external-search sources this message already has.
 */
export function externalSearchMessagePatch(
  finish: SearchReplyFinish,
  service: SearchService,
  existing: { citations?: readonly Citation[] | null; capabilityResults?: ChatMessage['capabilityResults'] } = {},
): Partial<ChatMessage> {
  const searchCitations: Citation[] = finish.citations.map((c) => ({
    url: c.url,
    title: c.title,
    snippet: c.snippet,
    source: 'external_search',
    index: c.number,
    query: c.query,
    serviceId: c.serviceId,
    serviceName: c.serviceName,
    retrievedAt: c.retrievedAt,
    ...(c.site ? { site: c.site } : {}),
    ...(c.date ? { date: c.date } : {}),
  }));
  const others = (existing.citations ?? []).filter((c) => c.source !== 'external_search');
  const citations = [...others, ...searchCitations];
  const record = externalSearchCapabilityResult(finish.facts, { reused: finish.sourcesLine?.reused === true, custom: service.custom === true });
  const capabilityResults = [
    ...(existing.capabilityResults ?? []).filter((r) => r.source !== 'external_search'),
    ...(record ? [record] : []),
  ];
  return {
    ...(citations.length > 0 ? { citations } : {}),
    ...(capabilityResults.length > 0 ? { capabilityResults } : {}),
    searchErrorCard: finish.errorCard
      ? {
        errorClass: finish.errorCard.errorClass,
        headline: finish.errorCard.headline,
        primaryAction: finish.errorCard.primaryAction,
        ...(finish.errorCard.secondaryAction ? { secondaryAction: finish.errorCard.secondaryAction } : {}),
        serviceId: service.id,
        serviceName: finish.errorCard.serviceName,
        switchTo: finish.errorCard.switchTo,
      }
      : undefined,
    searchNotice: finish.notice ?? undefined,
  };
}

// ── Tool ─────────────────────────────────────────────────────────────

function parseWebSearchArguments(raw: string): { query: string; count: number | null } {
  try {
    const value = JSON.parse(raw || '{}') as { query?: unknown; count?: unknown };
    return {
      query: typeof value.query === 'string' ? value.query : '',
      count: typeof value.count === 'number' ? value.count : null,
    };
  } catch {
    return { query: '', count: null };
  }
}

/**
 * The web_search entry of the generic ToolCallLoop: definition from plan.webSearchTool; execution goes through reply.search; failures are always neutral (not counted as consecutive failures).
 * A function means the reply's search state is opened only on the first call (library path: library sources numbered earlier enter the allocator via priorBatches).
 */
export function createWebSearchEntry(
  reply: ExternalSearchReply | { plan: SearchTurnPlan; reply: () => ExternalSearchReply },
): ToolRegistryEntry {
  const plan = 'turn' in reply ? reply.turn.plan : reply.plan;
  const getReply = 'turn' in reply ? () => reply : reply.reply;
  const tool = plan.webSearchTool;
  if (!tool) throw new Error('web_search entry without plan.webSearchTool');
  const definition = { type: 'function', function: { name: tool.name, description: tool.description, parameters: tool.parameters } } as unknown as ProxyToolDefinition;
  return {
    name: tool.name,
    scope: 'web',
    definition,
    async execute(call, context) {
      const args = parseWebSearchArguments(call.function.arguments);
      return { content: await getReply().search(args.query, args.count, context.signal) };
    },
    failureDisposition: () => ({ kind: 'neutral', code: 'web_search_unavailable', message: TOOL_MESSAGES.unavailable }),
  };
}

// ── Shared wiring of tool-loop send paths (MCP / library agent) ────────────────────────

export interface AgentExternalSearchInput {
  store: StoreApi<AppStore>;
  provider: Provider;
  model: AIModel;
  conversationId: string;
  reasoningMode: ReasoningMode;
  webSearchEnabled: boolean;
  userText: string;
  searchRegenerate?: { action: SearchRegenerateAction; previousCitations?: readonly Citation[] | null };
  host: { library: boolean; mcp: boolean };
  /** Attachment-scope options (relay reads relayTransport to decide this turn's protocol). */
  streamOptions?: StreamOptions;
}

export interface AgentExternalSearch {
  readonly plan: SearchTurnPlan;
  /** The search state of the current reply (not opened yet = undefined). */
  reply(): ExternalSearchReply | undefined;
  /** Pre-search / reuse into [D] (prepareToolLoopContext.webDynamic); tool path = undefined. */
  webDynamic?: (budget: { B: number | null; rhoHi: number }) => Promise<string | null>;
  /**
   * The web_search entry for the tool path (opens state on the first call; priorBatches takes the sources already numbered at that moment).
   * memoryTools = a memory tool entry really exists in the same registry (hostMemoryToolsRegistered): recompute this turn's plan tool host from it.
   */
  toolEntry(
    budget: () => { B: number | null; rhoHi: number },
    priorBatches?: () => CitationBatch[],
    registry?: { memoryTools: boolean },
  ): ToolRegistryEntry | undefined;
  /** First leg with web_search got 400 / 422: recompute the plan, and when rerouting to pre-search return the [D] content (and remember conversation x modelKey); otherwise null. */
  replanAfterRejection(status: number, budget: { B: number | null; rhoHi: number }): Promise<string | null>;
  /** Finalize persistence patch (on stop, send stopped first). */
  patch(existing: Pick<ChatMessage, 'citations' | 'capabilityResults'>, stopped: boolean): Partial<ChatMessage>;
}

/** External search for the tool-loop path: no local external source / not an external path = null (behavior as before). */
export async function prepareAgentExternalSearch(input: AgentExternalSearchInput): Promise<AgentExternalSearch | null> {
  if (providerControlsAreManaged(input.provider)) return null;
  const connections = searchConnectionsFromProviders(input.store.getState().providers ?? []);
  const context = await loadExternalSearchSendContext({
    provider: input.provider, model: input.model, conversationId: input.conversationId, reasoningMode: input.reasoningMode,
    webOn: input.webSearchEnabled, connections,
  });
  const wireProtocol = canonicalFinalTransport(input.provider.kind === 'relay'
    ? input.streamOptions?.relayTransport
    : resolveCatalogModel(input.model.id, input.provider.kind)?.transport ?? input.model.transport);
  const modelKey = externalSearchModelKey(input.provider.id, input.model.id);
  // The memory tool is reported by toolEntry after the registry is settled (it only affects the tool host description, not the path / pre-search choice).
  let memoryTools = false;
  const planInput = (rejection: { status: number; leg: number } | null): PlanExternalSearchInput => ({
    toolCall: resolveModelCapabilityEvidence({ key: 'tool_call', provider: input.provider, model: input.model }).support,
    host: {
      ...input.host, memoryTools,
      nativeMoonshotLoop: false, serverMaxSteps: effectiveMaxSteps(currentMcpRuntimeConfig()), continuationKind: 'tool_loop',
    },
    thinking: { on: searchThinkingOn(input.reasoningMode), protocol: searchThinkingProtocol(input.provider, wireProtocol), continuationStateAvailable: true },
    ...(input.searchRegenerate ? { regenerate: input.searchRegenerate } : {}),
    userText: input.userText,
    B: null,
    upstreamRejection: rejection,
    toolsRejectedBefore: toolsRejectedBefore(input.conversationId, modelKey),
  });
  const firstTurn = planExternalSearchTurn(context, planInput(null));
  if (!firstTurn || !context) return null;
  let turn: ExternalSearchTurn = firstTurn;
  const execute = createExternalSearchExecutor(turn.binding, { uid: context.data.uid, connections });
  let current: ExternalSearchReply | undefined;
  const start = (plan: SearchTurnPlan, budget: { B: number | null; rhoHi: number }, priorBatches?: readonly CitationBatch[]) => {
    clearExternalSearchActivity(input.conversationId);
    for (const t of plan.telemetry) trackEvent(t.event as TelemetryEventName, t.props);
    current = startExternalSearchReply({
      turn,
      plan,
      B: budget.B,
      rhoHi: budget.rhoHi,
      execute,
      ...(priorBatches ? { priorBatches } : {}),
      onActivity: (detail) => {
        setExternalSearchActivity(input.conversationId, detail);
        input.store.getState().setStreamingActivity(input.conversationId, detail ? 'external_search' : null);
      },
      track: (event, props) => trackEvent(event, props),
    });
    return current;
  };
  const dynamicFor = async (reply: ExternalSearchReply): Promise<string | null> => {
    const plan = reply.turn.plan;
    if (plan.reuse) return reply.reuse(input.searchRegenerate?.previousCitations) || null;
    return plan.presearch ? reply.search(plan.presearch.query, plan.presearch.count) : null;
  };
  const toolPath = turn.plan.requestHasWebSearchTool;
  return {
    get plan() {
      return turn.plan;
    },
    reply: () => current,
    ...(!toolPath && (turn.plan.presearch || turn.plan.reuse)
      ? { webDynamic: (budget: { B: number | null; rhoHi: number }) => dynamicFor(start(turn.plan, budget)) }
      : {}),
    toolEntry(budget, priorBatches, registry) {
      if (!toolPath) return undefined;
      if (registry && registry.memoryTools !== memoryTools && !current) {
        memoryTools = registry.memoryTools;
        turn = planExternalSearchTurn(context, planInput(null)) ?? turn;
      }
      const toolTurn = turn;
      return createWebSearchEntry({ plan: toolTurn.plan, reply: () => current ?? start(toolTurn.plan, budget(), priorBatches?.()) });
    },
    async replanAfterRejection(status, budget) {
      if (!toolPath) return null;
      const replanned = planExternalSearchTurn(context, planInput({ status, leg: 0 }));
      if (!replanned?.plan.presearch) return null;
      rememberToolsRejected(input.conversationId, modelKey);
      return dynamicFor(start(replanned.plan, budget));
    },
    patch(existing, stopped) {
      clearExternalSearchActivity(input.conversationId);
      if (!current) return {};
      if (stopped) current.stop();
      return externalSearchMessagePatch(current.finish(), current.turn.binding.service, existing);
    },
  };
}
