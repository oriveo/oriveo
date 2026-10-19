/**
 * search_memory per-send runtime (memory-search.v1 rules 4–6, legRules 1–5).
 * - resolveSearchMemoryMode: conversation memory, the propose_memory client-tool predicate and degraded set
 *   (one set for both tools), and the visible L3 item count, then the shared searchMemoryMode.
 * - createSearchMemoryTurn: one turn's calls against the memory-recall index; excludeIds = the [D] recall ids of the
 *   plan plus ids returned by earlier calls; the tool_result is fitted to the request's recallMax and rhoHi.
 * - createSearchMemoryEntry: the same turn as a tool-loop registry entry (MCP / library), registered after
 *   propose_memory; it takes a step but records none.
 */
import type { StoreApi } from 'zustand';
import type { AIModel, Provider } from '@oriveo/shared';
import type { GenerationParameterOverrides } from '@oriveo/core/providers/request-builders/types';
import type { ContextPlan, RecallEntry } from '@oriveo/core/context/assemble';
import { CONTEXT_BUDGET_CONSTANTS, ContextBudget } from '@oriveo/core/context/budget';
import {
  SEARCH_MEMORY_TOOL,
  SEARCH_MEMORY_TOOL_NAME,
  MEMORY_SEARCH_EMPTY_RESULT,
  searchMemory,
  searchMemoryMode,
  searchMemoryReturnedIds,
  searchMemoryToolResult,
} from '@oriveo/core/context/memory-search';
import type { ProxyToolDefinition } from '@oriveo/core/providers/request-builders/runtime';
import type { ToolRegistryEntry } from '@oriveo/core/tools/tool-loop-contracts';
import type { AppStore } from '../store/app-store';
import { sameNormalizedID } from '../../utils/id-utils';
import { memoryRecallIndexFor, recallableMemoryItemCount } from '../memory/memory-recall-runtime';
import {
  conversationMemoryEnabled,
  isProposeMemoryDegraded,
  memoryToolsConnectionSupported,
} from './propose-memory-runtime';

/** Wire definition (canonical OpenAI function shape; the route projects it per protocol). */
export const SEARCH_MEMORY_PROXY_TOOL = SEARCH_MEMORY_TOOL as unknown as ProxyToolDefinition;

export function isSearchMemoryToolName(name: string): boolean {
  return name === SEARCH_MEMORY_TOOL_NAME;
}

export interface ResolveSearchMemoryModeInput {
  store: StoreApi<AppStore>;
  conversationId: string;
  provider: Provider | undefined;
  model: AIModel | undefined;
  /** Effective web search of this send (same exclusions as propose_memory). */
  webSearchEnabled?: boolean;
  /** Generation parameters this request will send; active json_schema keeps the tool off (D-296). */
  generationParameters?: GenerationParameterOverrides;
  /** Native file parts this request carries would be refused by its line's tool loop (D-299). */
  nativeFilesBlockToolLoop?: boolean;
  nowMs?: number;
}

/** Purpose is chat at every call site: fresh sends, retries and regenerations alike (the tool only reads). */
export function resolveSearchMemoryMode(input: ResolveSearchMemoryModeInput): 'tool' | 'none' {
  const { store, conversationId, provider, model } = input;
  const conv = store.getState().conversations.find((c) => sameNormalizedID(c.id, conversationId));
  return searchMemoryMode({
    purpose: 'chat',
    memoryEnabled: conversationMemoryEnabled(store, conversationId),
    connectionSupportsTools: memoryToolsConnectionSupported(
      provider, model, input.webSearchEnabled, input.generationParameters, input.nativeFilesBlockToolLoop,
    ),
    degraded: provider !== undefined && model !== undefined && isProposeMemoryDegraded(provider.id, model.id),
    recallableItems: recallableMemoryItemCount({
      items: store.getState().memoryItems,
      conversationId,
      folderId: conv?.folderID ?? null,
      ...(input.nowMs !== undefined ? { nowMs: input.nowMs } : {}),
    }),
  });
}

/** recallMax of a plan's budget; unknown window = no cap (same as the [D] recall fitting). */
export function planRecallMax(plan: Pick<ContextPlan, 'budget'>): number | null {
  return plan.budget.W !== null && plan.budget.B !== null ? ContextBudget.derive(plan.budget.B).recallMax : null;
}

/** Ids of the plan's [D] recall: recall entries that made it into memoryIds. */
export function planRecallIds(plan: Pick<ContextPlan, 'memoryIds'>, recall: readonly RecallEntry[]): string[] {
  const rendered = new Set(plan.memoryIds);
  return recall.filter((entry) => rendered.has(entry.id)).map((entry) => entry.id);
}

export interface SearchMemoryTurnInput {
  store: StoreApi<AppStore>;
  conversationId: string;
  folderId: string | null;
  /** The current plan's [D] recall ids (read per call: a re-planned leg changes them). */
  recallIds: () => readonly string[];
  recallMax: () => number | null;
  rhoHi?: () => number;
  nowMs?: () => number;
}

export interface SearchMemoryTurn {
  /** Runs one call and returns its tool_result text. */
  run(argumentsJson: string): string;
  /** Ids returned to the model so far, in call order. */
  readonly returnedIds: string[];
  /** Hits returned to the model so far, as recall entries (thinking-model resend appends them to [D]). */
  readonly returnedEntries: RecallEntry[];
}

export function createSearchMemoryTurn(input: SearchMemoryTurnInput): SearchMemoryTurn {
  let calls = 0;
  const entries: RecallEntry[] = [];
  return {
    run(argumentsJson) {
      const prior = calls;
      calls += 1;
      try {
        const index = memoryRecallIndexFor(input.store.getState().memoryItems ?? []);
        const outcome = searchMemory(index, argumentsJson, {
          conversationId: input.conversationId,
          folderId: input.folderId,
          nowMs: input.nowMs?.() ?? Date.now(),
          excludeIds: [...input.recallIds(), ...entries.map((entry) => entry.id)],
        }, prior);
        const rho = input.rhoHi?.() ?? CONTEXT_BUDGET_CONSTANTS.rho0;
        const returned = new Set(searchMemoryReturnedIds(outcome, input.recallMax(), rho));
        entries.push(...outcome.hits.filter((hit) => returned.has(hit.id)).map((hit) => ({ id: hit.id, text: hit.text, date: hit.date })));
        return searchMemoryToolResult(outcome, input.recallMax(), rho);
      } catch (error) {
        console.warn('[memory-search] search failed', error);
        return MEMORY_SEARCH_EMPTY_RESULT;
      }
    },
    get returnedIds() {
      return entries.map((entry) => entry.id);
    },
    get returnedEntries() {
      return [...entries];
    },
  };
}

/** Tool-loop registry entry: scope memory, no step record; failures are neutral and answer the empty result. */
export function createSearchMemoryEntry(turn: SearchMemoryTurn): ToolRegistryEntry {
  return {
    name: SEARCH_MEMORY_TOOL_NAME,
    scope: 'memory',
    definition: SEARCH_MEMORY_PROXY_TOOL,
    async execute(call) {
      return { content: turn.run(call.function.arguments) };
    },
    failureDisposition: () => ({ kind: 'neutral', code: 'search_memory_failed', message: MEMORY_SEARCH_EMPTY_RESULT }),
  };
}
