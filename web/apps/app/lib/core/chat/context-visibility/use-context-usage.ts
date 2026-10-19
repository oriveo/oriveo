import { useEffect, useRef, useState } from 'react';
import { ContextBudget } from '@oriveo/core/context/budget';
import type { ChatMessage, Provider } from '@oriveo/shared';
import { getContextManifests } from '../../../infra/storage/context-ledger-store';
import { listContextCheckpoints } from '../../../infra/storage/context-checkpoint-store';
import { separatorHistoryOf } from '../context-compaction/use-compaction-separator';
import type { CompactionSeparatorMessage } from '../context-compaction/context-compaction-presentation';
import { ContextCompactionStore } from '../context-compaction/context-compaction-store';
import { chatUserMaxOutputFor, displayRhoHiOf, windowOf } from '../context-pipeline/chat-context';
import { useAppStore } from '../../../../providers/StoreProvider';
import { resolveContextDefaultCap } from '../../context-cap-preferences';
import type { BudgetCapOption } from '@oriveo/core/context/budget';
import { summarizeContextUsage, type ContextUsageSummary, type UsageCheckpointInput } from './usage-summary';

export interface ContextUsageState {
  /** Conversation the summary was read for; a mismatch with the current conversation means stale. */
  conversationId: string;
  summary: ContextUsageSummary;
  /** Latest valid checkpoint; null if none (the panel uses it to show the condense count and the checkpoint-only buttons). */
  checkpoint: UsageCheckpointInput | null;
}

/**
 * Reads this session's ledger and latest valid checkpoint and hands them to summarizeContextUsage.
 * count = number of entries the checkpoint store lists for the session; summary tokens are estimated like the separator line (estimateMessage(text, rhoHi)).
 */
export async function readContextUsageState(
  conversationId: string,
  history: readonly CompactionSeparatorMessage[],
  rhoHi: number,
  currentB?: number | null,
): Promise<ContextUsageState> {
  const [manifests, latest, rows] = await Promise.all([
    getContextManifests(conversationId),
    ContextCompactionStore.latestValid(conversationId, history),
    listContextCheckpoints(conversationId),
  ]);
  let checkpoint: UsageCheckpointInput | null = null;
  if (latest) {
    checkpoint = {
      count: Math.max(1, rows.length),
      latestCreatedAt: latest.createdAt,
      latestSummaryTokens: ContextBudget.estimateMessage(latest.text, rhoHi),
    };
  }
  const current = currentB === undefined ? undefined : { B: currentB };
  return { conversationId, summary: summarizeContextUsage(manifests, checkpoint, current), checkpoint };
}

export async function readContextUsage(
  conversationId: string,
  history: readonly CompactionSeparatorMessage[],
  rhoHi: number,
): Promise<ContextUsageSummary> {
  return (await readContextUsageState(conversationId, history, rhoHi)).summary;
}

/**
 * Only accepts the current session's result: after switching sessions and before the new result is read back, the old session's usage is not shown.
 */
export function usageStateForConversation(
  state: ContextUsageState | null,
  conversationId: string | null | undefined,
): ContextUsageState | null {
  if (!state || !conversationId || state.conversationId !== conversationId) return null;
  return state;
}

/**
 * Recompute key: only message id + status are joined, so body changes while streaming do not re-read IndexedDB.
 */
export function usageRefreshKeyOf(messages: readonly ChatMessage[]): string {
  return messages.map((message) => `${message.id}:${message.state}`).join('|');
}

/**
 * Compute B from the session's current tier: same window inputs as the send path (windowOf + panel max output).
 * When the model is not found on the connection, returns undefined and the ledger's B is kept.
 */
export function currentUsageBudgetOf(
  provider: Provider | undefined,
  modelId: string | undefined,
  conversationId: string,
  cap: BudgetCapOption,
): number | null | undefined {
  const model = provider && modelId ? provider.models.find((m) => m.id === modelId) : undefined;
  if (!provider || !model) return undefined;
  const userMaxOutput = chatUserMaxOutputFor({ provider, model, conversationId, reasoningMode: 'automatic' });
  return ContextBudget.window(windowOf(provider, model, userMaxOutput, cap)).B;
}

/**
 * Usage: recomputed on session switch, message change, checkpoint change (including clearing), and session tier change.
 * No session id (draft) does not read the store and returns null; an unreadable store counts as none.
 */
export function useContextUsage(
  conversationId: string | null | undefined,
  messages: readonly ChatMessage[],
  provider: Provider | undefined,
  modelId: string | undefined,
): ContextUsageState | null {
  const refreshKey = usageRefreshKeyOf(messages);
  // The body is read from a ref: when the key is unchanged (while streaming) nothing is recomputed; when it changes the latest messages are used.
  const messagesRef = useRef(messages);
  messagesRef.current = messages;
  const [version, setVersion] = useState(0);
  const [state, setState] = useState<ContextUsageState | null>(null);
  // Session tier (same as contextCapOf): changing the tier recomputes the denominator immediately, without waiting for the next send.
  const cap = useAppStore((s): BudgetCapOption => {
    const conversation = conversationId ? s.conversations.find((c) => c.id === conversationId) : undefined;
    return conversation?.contextCap ?? resolveContextDefaultCap(s.preferences);
  });

  useEffect(() => {
    if (!conversationId) return undefined;
    return ContextCompactionStore.subscribeCheckpointChanges((changed) => {
      if (changed === conversationId) setVersion((v) => v + 1);
    });
  }, [conversationId]);

  useEffect(() => {
    if (!conversationId) {
      setState(null);
      return undefined;
    }
    let cancelled = false;
    void (async () => {
      let next: ContextUsageState | null = null;
      try {
        const rhoHi = await displayRhoHiOf(provider, modelId);
        const currentB = currentUsageBudgetOf(provider, modelId, conversationId, cap);
        next = await readContextUsageState(conversationId, separatorHistoryOf(messagesRef.current), rhoHi, currentB);
      } catch {
        next = null;
      }
      if (!cancelled) setState(next);
    })();
    return () => {
      cancelled = true;
    };
  }, [conversationId, refreshKey, provider, modelId, cap, version]);

  return usageStateForConversation(state, conversationId);
}
