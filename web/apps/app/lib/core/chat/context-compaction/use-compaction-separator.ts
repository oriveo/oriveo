import { useEffect, useMemo, useState } from 'react';
import { buildEffectiveUserContent, type ChatMessage, type Provider } from '@oriveo/shared';
import type { ContextCheckpointRow } from '../../../infra/storage/context-checkpoint-store';
import { displayRhoHiOf } from '../context-pipeline/chat-context';
import {
  compactionSeparatorOf,
  type CompactionSeparatorMessage,
  type CompactionSeparatorModel,
} from './context-compaction-presentation';
import { ContextCompactionStore } from './context-compaction-store';
import { createModelDisplayLookup } from '../../providers/model-display-lookup';

export interface CompactionSeparatorState {
  model: CompactionSeparatorModel;
  row: ContextCheckpointRow;
}

/** The full history on the same basis as latestValid: only user / assistant messages, with user text taken after quote expansion. */
export function separatorHistoryOf(messages: readonly ChatMessage[]): CompactionSeparatorMessage[] {
  const history: CompactionSeparatorMessage[] = [];
  for (const message of messages) {
    if (message.role !== 'user' && message.role !== 'assistant') continue;
    const text = message.text ?? '';
    history.push({
      id: message.id,
      role: message.role,
      text: message.role === 'user' && message.quoteContext ? buildEffectiveUserContent(text, message.quoteContext) : text,
    });
  }
  return history;
}

/** Model display name for the summary row of the separator: looks up the name in the current provider's model catalog by id; returns undefined when not found (the caller shows the id). */
export function compactionModelNameOf(provider: Provider | undefined): (modelId: string) => string | undefined {
  const lookup = createModelDisplayLookup(provider);
  return (modelId) => lookup.resolve(modelId)?.displayName;
}

/**
 * Transcript separator row: feeds all messages of the conversation to latestValid and the presentation model;
 * recomputed when the conversation / messages / provider change or the store changes (subscribeCheckpointChanges). An unreadable database counts as no row.
 */
export function useCompactionSeparator(
  conversationId: string | null | undefined,
  messages: readonly ChatMessage[],
  provider: Provider | undefined,
  modelId: string | undefined,
): CompactionSeparatorState | null {
  const history = useMemo(() => separatorHistoryOf(messages), [messages]);
  const [version, setVersion] = useState(0);
  const [state, setState] = useState<CompactionSeparatorState | null>(null);

  useEffect(() => {
    if (!conversationId) return undefined;
    return ContextCompactionStore.subscribeCheckpointChanges((changed) => {
      if (changed === conversationId) setVersion((v) => v + 1);
    });
  }, [conversationId]);

  useEffect(() => {
    if (!conversationId || history.length === 0) {
      setState(null);
      return undefined;
    }
    let cancelled = false;
    void (async () => {
      let next: CompactionSeparatorState | null = null;
      try {
        const [row, rhoHi] = await Promise.all([
          ContextCompactionStore.latestValid(conversationId, history),
          displayRhoHiOf(provider, modelId),
        ]);
        const model = compactionSeparatorOf(row, history, rhoHi, compactionModelNameOf(provider));
        if (row && model) next = { model, row };
      } catch {
        next = null;
      }
      if (!cancelled) setState(next);
    })();
    return () => {
      cancelled = true;
    };
  }, [conversationId, history, provider, modelId, version]);

  return state;
}
