/**
 * Registry entry for propose_memory: in tool mode the MCP / Library tool loops register it as the last item.
 * - Execution: create a candidate through the candidate repository's propose (counted per turn); the first create of the turn becomes a suggestion bar via a ticket; no step is recorded and nothing enters history.
 * - v3: an instruct with scope conversation goes to the "set as this conversation's instruction" bar (at most one per turn) and never enters memory suggestions.
 * - Every call returns the same fixed tool_result; a repository failure only warns and returns the same fixed result, so the model neither retries nor asks follow-ups.
 * - failureDisposition is always neutral: it neither counts toward consecutive failures nor resets them, and still occupies one tool step.
 */
import type { StoreApi } from 'zustand';
import {
  PROPOSE_MEMORY_TOOL,
  PROPOSE_MEMORY_TOOL_NAME,
  PROPOSE_MEMORY_TOOL_RESULT,
} from '@oriveo/core/context/memory-propose';
import type { ProxyToolDefinition } from '@oriveo/core/providers/request-builders/runtime';
import type { ToolRegistryEntry } from '@oriveo/core/tools/tool-loop-contracts';
import type { AppStore } from '../store/app-store';
import { getActiveUIDSync } from '../../infra/storage/partition';
import { createMemoryCandidateRepository, type MemoryCandidateRepository } from '../memory/memory-candidate-repository';
import { createMemoryItemRepository } from '../memory/memory-item-repository';
import { resolveProposedMemorySuggestion, type MemorySuggestionTicket } from './conversation-instructions/memory-suggestion';
import { offerInstructSuggestion } from './conversation-instructions/directive-suggestion';

export interface ProposeMemoryEntryInput {
  ticket: MemorySuggestionTicket;
  store: StoreApi<AppStore>;
  /** Candidate repository of this partition; fetched lazily on first execution (lazy import to avoid a cycle). */
  repo: () => Promise<MemoryCandidateRepository>;
  /** Body of the user's new message this turn: sourceQuote must come from it. */
  userText: string;
  /** messageId is the id of this turn's user message (the candidate source). */
  ids: { conversationId: string; messageId: string; folderId: string | null };
}

/** Wire tool definition (canonical OpenAI function shape; the route projects it per protocol). */
const PROPOSE_MEMORY_PROXY_TOOL = PROPOSE_MEMORY_TOOL as unknown as ProxyToolDefinition;

export function createProposeMemoryEntry(input: ProposeMemoryEntryInput): ToolRegistryEntry {
  let proposedInTurn = 0;
  let instructedInTurn = 0;
  return {
    name: PROPOSE_MEMORY_TOOL_NAME,
    scope: 'memory',
    definition: PROPOSE_MEMORY_PROXY_TOOL,
    async execute(call) {
      const prior = proposedInTurn;
      proposedInTurn += 1;
      try {
        const repository = await input.repo();
        const candidate = await repository.propose(call.function.arguments, prior, {
          userText: input.userText,
          messageId: input.ids.messageId,
          conversationId: input.ids.conversationId,
          folderId: input.ids.folderId,
          priorInstructInTurn: instructedInTurn,
          onInstruct: (sentence) => {
            instructedInTurn += 1;
            offerInstructSuggestion(input.store, input.ticket, sentence);
          },
        });
        resolveProposedMemorySuggestion(input.store, input.ticket, candidate);
      } catch (error) {
        console.warn('[memory-candidate] propose failed', error);
      }
      return { content: PROPOSE_MEMORY_TOOL_RESULT };
    },
    failureDisposition: () => ({ kind: 'neutral', code: 'propose_memory_failed', message: PROPOSE_MEMORY_TOOL_RESULT }),
  };
}

/** Candidate repository of the current partition (built the same way as applyProposeMemoryCalls on an ordinary send). */
export function currentMemoryCandidateRepository(store: StoreApi<AppStore>): () => Promise<MemoryCandidateRepository> {
  let cached: Promise<MemoryCandidateRepository> | null = null;
  return () => {
    cached ??= (async () => {
      const uid = getActiveUIDSync();
      // Lazy import: bootstrap pulls in the chat modules, so a static import would form a cycle (same as generateMemoryCandidate).
      const { getOrCreateStableWebDeviceId } = await import('../bootstrap');
      const items = createMemoryItemRepository({ store, uid, deviceId: getOrCreateStableWebDeviceId() });
      return createMemoryCandidateRepository({ uid, items });
    })();
    return cached;
  };
}
