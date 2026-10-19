import { ContextBudget } from '@oriveo/core/context/budget';
import { formatCompactNumber } from '@oriveo/core/context/compact-number';
import type { ContextCheckpointKind, ContextCheckpointRow } from '../../../infra/storage/context-checkpoint-store';

/*
 * Pure presentation model of the compaction UI. Reads only the latestValid row;
 * before/after token counts are computed at display time with this client's estimator (the caller passes rhoHi from the same source as the send path) and are not stored.
 */

export interface CompactionSeparatorMessage {
  id: string;
  role: string;
  text: string;
}

export interface CompactionSeparatorModel {
  kind: ContextCheckpointKind;
  /** summary: messagesCovered; fallback: the number of assistant messages among the messagesCovered messages ending at coversTo. */
  count: number;
  /** summary only: the estimated token sum of the count messages ending at coversTo. */
  before: number | null;
  /** summary only: estimated tokens of the checkpoint text. */
  after: number | null;
  /** Number of verbatim user messages kept. */
  kept: number;
  model: string;
  /** The separator row is attached after this message (= coversTo). */
  anchorMessageId: string;
}

export type CompactionCostState =
  | { kind: 'noExtraCost' }
  | { kind: 'unavailable' }
  | { kind: 'amount'; amount: number };

export interface CompactionDetailModel {
  /** Present only when non-empty; shown read-only. */
  summary?: string;
  kept: number;
  model: string;
  cost: CompactionCostState;
  /** Millisecond timestamp. */
  createdAt: number;
}

/**
 * Returns null (draws nothing) when there is no row or coversTo is not among the loaded messages.
 * modelNameOf: looks up the display name by id in the model catalog, used only for summary rows; the id is shown when it is missing or not given.
 */
export function compactionSeparatorOf(
  row: ContextCheckpointRow | null,
  messages: readonly CompactionSeparatorMessage[],
  rhoHi: number,
  modelNameOf?: (modelId: string) => string | null | undefined,
): CompactionSeparatorModel | null {
  if (!row) return null;
  const coversIndex = messages.findIndex((m) => m.id === row.coversTo);
  if (coversIndex < 0) return null;
  // Same rule as iOS / Android: count messagesCovered messages ending at coversTo (earlier history may contain uncovered messages).
  const covered = messages.slice(Math.max(0, coversIndex + 1 - row.messagesCovered), coversIndex + 1);
  const base = { kept: row.userMessageIds.length, model: row.model, anchorMessageId: row.coversTo };
  if (row.kind === 'fallback') {
    return {
      kind: 'fallback',
      count: covered.filter((m) => m.role === 'assistant').length,
      before: null,
      after: null,
      ...base,
    };
  }
  const displayName = modelNameOf?.(row.model)?.trim();
  return {
    kind: 'summary',
    count: row.messagesCovered,
    before: covered.reduce((sum, m) => sum + ContextBudget.estimateMessage(m.text, rhoHi), 0),
    after: ContextBudget.estimateMessage(row.text, rhoHi),
    ...base,
    model: displayName || row.model,
  };
}

export function compactionDetailOf(row: ContextCheckpointRow): CompactionDetailModel {
  const cost: CompactionCostState =
    row.kind === 'fallback'
      ? { kind: 'noExtraCost' }
      : row.cost === null
        ? { kind: 'unavailable' }
        : { kind: 'amount', amount: row.cost };
  return {
    ...(row.summary ? { summary: row.summary } : {}),
    kept: row.userMessageIds.length,
    model: row.model,
    cost,
    createdAt: row.createdAt,
  };
}

/** Same compact number format as MessageMeta: uses the shared table (compact-number.v1.json), rounds down, no Intl compact. */
export function formatCompactCount(value: number, locale: string): string {
  return formatCompactNumber(value, locale);
}
