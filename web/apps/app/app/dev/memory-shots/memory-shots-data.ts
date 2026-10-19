/**
 * Sample data for the memory page family: every value comes from the shared manifest `shared/test-fixtures/shots/memory.v1.json` (the entry reads it and passes it in as a parameter);
 * items are built through production `MemoryItems.canonical`, candidates in the production `MemoryCandidateRecord` shape (fingerprints use production `memoryIntentFingerprint`).
 * Only imported dynamically from the dev branch; items go only into the in-memory store, candidates only into the in-memory IndexedDB swapped in by the fence.
 */
import type { StoreApi } from 'zustand';
import type { Folder } from '@oriveo/shared';
import { MemoryItems, type MemoryItem, type MemoryKind, type MemoryLayer, type MemoryScope, type MemoryStatus } from '@oriveo/core/context/memory-items';
import { memoryIntentFingerprint, type MemoryCandidateRecord } from '@oriveo/core/context/memory-intent';
import { MEMORY_INTENT_CANDIDATE_TTL_MS } from '@oriveo/core/context/memory-intent-lexicon';
import type { AppStore } from '../../../lib/core/store/app-store';
import { putMemoryCandidateRows } from '../../../lib/infra/storage/memory-candidate-store';
import { getActiveUIDSync } from '../../../lib/infra/storage/partition';
import type { MemoryShotPage } from './memory-shots-pages';

/** The part of the shared manifest `oriveo.shots.memory/v1` this client reads (keys starting with `$` are ignored). */
export interface MemoryShotsManifestItem {
  id: string;
  layer?: MemoryLayer;
  kind: MemoryKind;
  content: string;
  status?: MemoryStatus;
  pinned?: boolean;
  scope?: { type: MemoryScope['type']; id: string | null };
  conflictGroupId?: string;
  occurredAt?: string;
  updatedAt?: string;
}

export interface MemoryShotsManifestCandidate {
  id: string;
  proposedLayer: MemoryLayer;
  proposedKind: MemoryKind;
  content: string;
  confidence: number;
  createdAt: string;
  occurredAt?: string;
  scope?: { type: MemoryScope['type']; id: string | null };
}

export interface MemoryShotsManifestPage {
  name: string;
  items: 'none' | 'all';
  candidates: 'none' | 'all';
  preset?: { editItem?: string; rawTooLongAt?: number };
}

export interface MemoryShotsManifest {
  schema: 'oriveo.shots.memory/v1';
  clock: string;
  deviceId: string;
  folders: Array<{ id: string; name: string }>;
  items: MemoryShotsManifestItem[];
  candidates: MemoryShotsManifestCandidate[];
  pages: MemoryShotsManifestPage[];
  rawTooLongSegment: { unit: string; repeat: number };
}

/** Whether the manifest is complete (the entry refuses to open an incomplete manifest). */
export function isCompleteMemoryShotsManifest(value: unknown): value is MemoryShotsManifest {
  if (typeof value !== 'object' || value === null) return false;
  const m = value as Partial<MemoryShotsManifest>;
  return m.schema === 'oriveo.shots.memory/v1'
    && typeof m.clock === 'string' && Number.isFinite(Date.parse(m.clock))
    && typeof m.deviceId === 'string'
    && Array.isArray(m.folders) && Array.isArray(m.items) && Array.isArray(m.candidates) && Array.isArray(m.pages)
    && typeof m.rawTooLongSegment === 'object' && m.rawTooLongSegment !== null
    && typeof m.rawTooLongSegment.unit === 'string' && typeof m.rawTooLongSegment.repeat === 'number';
}

/** The one action to simulate after entering each page. */
export type MemoryShotDrive =
  | { kind: 'none' }
  /** Open the raw-text view, replace the body with text and tap save, so the production raw-text view reports too long. */
  | { kind: 'rawTooLong'; text: string };

export interface MemoryShotPlan {
  /** page = the production memory page; inbox = the production memory suggestions page. */
  target: 'page' | 'inbox';
  /** Query string written to the address bar before entering the page (the editor page uses the production `?edit=<id>`). */
  query: string;
  items: MemoryItem[];
  folders: Folder[];
  candidates: MemoryCandidateRecord[];
  /** This device's id (in a conflict pair, the one whose id != conflictGroupId is this device's copy). */
  deviceId: string;
  /** Fixed clock (milliseconds). */
  clockMs: number;
  drive: MemoryShotDrive;
}

/** Manifest item -> production item (omitted fields take the contract defaults). */
export function memoryShotItems(manifest: MemoryShotsManifest): MemoryItem[] {
  return manifest.items.map((entry) => MemoryItems.canonical({
    id: entry.id,
    layer: entry.layer,
    kind: entry.kind,
    status: entry.status,
    content: entry.content,
    pinned: entry.pinned,
    scope: entry.scope,
    conflictGroupId: entry.conflictGroupId ?? null,
    occurredAt: entry.occurredAt ?? null,
    updatedAt: entry.updatedAt ?? null,
    mutationId: `shots-${entry.id}`,
    deviceId: manifest.deviceId,
  }));
}

/** Manifest suggestion -> production candidate record (pending; the 30-day validity counts from createdAt). */
export function memoryShotCandidates(manifest: MemoryShotsManifest): MemoryCandidateRecord[] {
  return manifest.candidates.map((entry) => {
    const createdAtMs = Date.parse(entry.createdAt);
    return {
      id: entry.id,
      status: 'pending',
      proposedLayer: entry.proposedLayer,
      proposedKind: entry.proposedKind,
      content: entry.content,
      scope: { type: entry.scope?.type ?? 'global', id: entry.scope?.id ?? null },
      source: { type: 'conversation', conversationId: null, messageIds: [], observedAtMs: createdAtMs },
      sensitivity: 'normal',
      confidence: entry.confidence,
      fingerprint: memoryIntentFingerprint(entry.content),
      createdAtMs,
      expiresAtMs: createdAtMs + MEMORY_INTENT_CANDIDATE_TTL_MS,
      resolvedAtMs: null,
    };
  });
}

/**
 * Body for the over-long raw-text page: segment number `index` of the production rawRender raw text (counted from 0 after dropping empty segments, the same numbering as the tooLong index of rawApply)
 * is replaced with unit x repeat.
 */
export function memoryRawTooLongText(items: readonly MemoryItem[], manifest: MemoryShotsManifest, index: number): string {
  const separator = MemoryItems.constants.rawViewSeparator;
  const segments: string[][] = [[]];
  for (const line of MemoryItems.rawRender([...items]).split('\n')) {
    if (line.replace(/\r$/, '') === separator) segments.push([]);
    else segments[segments.length - 1]!.push(line);
  }
  let seen = -1;
  const replaced = segments.map((lines) => {
    if (lines.join('\n').trim() === '') return lines;
    seen += 1;
    return seen === index ? [manifest.rawTooLongSegment.unit.repeat(manifest.rawTooLongSegment.repeat).trimEnd()] : lines;
  });
  if (seen < index) throw new Error(`[memory-shots] raw text has no segment ${index}`);
  return replaced.map((lines) => lines.join('\n')).join(`\n${separator}\n`);
}

export function memoryShotPlan(page: MemoryShotPage, manifest: MemoryShotsManifest): MemoryShotPlan {
  const entry = manifest.pages.find((p) => p.name === page);
  if (!entry) throw new Error(`[memory-shots] manifest has no page ${page}`);
  const items = entry.items === 'all' ? memoryShotItems(manifest) : [];
  const editItem = entry.preset?.editItem;
  const tooLongAt = entry.preset?.rawTooLongAt;
  return {
    target: page === 'memoryInbox' ? 'inbox' : 'page',
    query: editItem ? `?edit=${encodeURIComponent(editItem)}` : '',
    items,
    folders: manifest.folders.map((folder, index) => ({
      id: folder.id,
      name: folder.name,
      sortOrder: index,
      createdAt: manifest.clock,
      updatedAt: manifest.clock,
    })),
    candidates: entry.candidates === 'all' ? memoryShotCandidates(manifest) : [],
    deviceId: manifest.deviceId,
    clockMs: Date.parse(manifest.clock),
    drive: tooLongAt === undefined ? { kind: 'none' } : { kind: 'rawTooLong', text: memoryRawTooLongText(items, manifest, tooLongAt) },
  };
}

/** Write into the in-memory store and the fenced in-memory database; never touches the real database. */
export async function applyMemoryShotPlan(plan: MemoryShotPlan, store: StoreApi<AppStore>): Promise<void> {
  store.setState({ memoryItems: plan.items, folders: plan.folders });
  await putMemoryCandidateRows(
    plan.candidates.map((candidate) => ({ id: candidate.id, status: candidate.status, candidate })),
    getActiveUIDSync(),
  );
}
