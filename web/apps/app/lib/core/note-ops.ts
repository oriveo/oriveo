/**
 * Note operations: store plus sync in one transaction.
 *
 * UI and capture layers only call this file; they never touch store actions or the sync adapter
 * directly. Every write also fires the matching didXxx to notify the sync port. On plans without
 * sync, getSyncAdapter() returns null and the write stays local, which is how local notes stay
 * unlimited while sync remains a paid capability.
 *
 * Monetisation is gated on features.sync alone; note count is never gated, so there is no quota
 * check and no gating selector here.
 */
import type { StoreApi } from 'zustand';
import type { AppStore } from './store/app-store';
import type { AIModel, ChatMessage, Conversation, Note, NoteFolder, ProvenanceEntry, Provider, ProviderKind } from '@oriveo/shared';
import { getProviderDisplayName } from '@oriveo/config';
import { getSyncAdapter } from './sync-port';
import { createCanonicalUUID, normalizeNoteIDs, normalizeUUID, sameNormalizedID } from '../utils/id-utils';

/**
 * The placeholder title is the first non-empty line of the body; no AI titling.
 * It takes the clean text: pure structure lines (table separators such as |---|, code fences)
 * are skipped, and leading markdown markers on the first line (heading #, quote >, list bullets,
 * table pipes, emphasis) are stripped, so a table or code body does not produce a title like
 * "| a | b |".
 */
function placeholderTitle(body: string): string {
  for (const line of displayBodyForTitle(body).split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    if (/^[|\s:+-]+$/.test(trimmed)) continue; // table separator rows such as |---|:--:|, and hr
    if (/^(```|~~~)/.test(trimmed)) continue;  // code fence
    const clean = trimmed
      .replace(/^#{1,6}\s+/, '')
      .replace(/^>\s?/, '')
      .replace(/^[-*+]\s+/, '')
      .replace(/^\d+\.\s+/, '')
      .replace(/\|/g, ' ')
      .replace(/[*_`~]/g, '')
      .replace(/\s+/g, ' ')
      .trim();
    if (clean) return clean.slice(0, 200);
  }
  return '';
}

function displayBodyForTitle(body: string): string {
  const lines = body.split('\n');
  const index = lines.findIndex((line) => line.trim().startsWith('## Cross-check'));
  if (index < 0) return body;
  return lines.slice(index + 1).join('\n').trim() || body;
}

/**
 * The placeholder title prefers the question that produced the note (sourcePrompt): in a list it
 * is far easier to recognise than the first line of the answer, which is often a table header or
 * a subheading. Falls back to the first line of the body when there is no prompt.
 */
function placeholderTitleFromSource(sourcePrompt: string | undefined, body: string): string {
  return placeholderTitle(sourcePrompt ?? '') || placeholderTitle(body);
}

export interface CreateNoteInput {
  body: string;
  captureKind: Note['captureKind'];
  /** When non-empty, titleSource becomes 'manual'; otherwise the placeholder is the first line of the body */
  title?: string;
  bodySnapshot?: string;
  userNote?: string;
  tags?: string[];
  noteFolderID?: string;
  sourceConversationId?: string;
  sourceMessageId?: string;
  sourceModelID?: string;
  sourceModelName?: string;
  sourceProviderKind?: ProviderKind;
  sourceProviderName?: string;
  sourcePrompt?: string;
  provenance?: ProvenanceEntry[];
  isPinned?: boolean;
}

/** Create a note in the store and notify the sync port. Returns the created Note. */
export function createNote(store: StoreApi<AppStore>, input: CreateNoteInput): Note {
  const now = new Date().toISOString();
  const manualTitle = typeof input.title === 'string' && input.title.trim().length > 0;

  const note: Note = normalizeNoteIDs({
    id: createCanonicalUUID(),
    title: manualTitle ? input.title!.trim() : placeholderTitleFromSource(input.sourcePrompt, input.body),
    titleSource: manualTitle ? 'manual' : 'placeholder',
    body: input.body,
    tags: input.tags ?? [],
    captureKind: input.captureKind,
    createdAt: now,
    updatedAt: now,
    ...(input.bodySnapshot !== undefined ? { bodySnapshot: input.bodySnapshot } : {}),
    ...(input.userNote !== undefined ? { userNote: input.userNote } : {}),
    ...(input.noteFolderID ? { noteFolderID: input.noteFolderID } : {}),
    ...(input.sourceConversationId ? { sourceConversationId: input.sourceConversationId } : {}),
    ...(input.sourceMessageId ? { sourceMessageId: input.sourceMessageId } : {}),
    ...(input.sourceModelID ? { sourceModelID: input.sourceModelID } : {}),
    ...(input.sourceModelName ? { sourceModelName: input.sourceModelName } : {}),
    ...(input.sourceProviderKind ? { sourceProviderKind: input.sourceProviderKind } : {}),
    ...(input.sourceProviderName ? { sourceProviderName: input.sourceProviderName } : {}),
    ...(input.sourcePrompt ? { sourcePrompt: input.sourcePrompt } : {}),
    ...(input.isPinned ? { isPinned: true } : {}),
    ...(input.provenance && input.provenance.length > 0 ? { provenance: input.provenance } : {}),
  });

  store.getState().addNote(note);
  getSyncAdapter()?.didCreateNote(note);
  return note;
}

export function isDiscardableEmptyBlankNote(note: Note): boolean {
  return !note.deletedAt &&
    note.captureKind === 'blank' &&
    note.titleSource === 'placeholder' &&
    note.title.trim().length === 0 &&
    note.body.trim().length === 0 &&
    (!note.bodySnapshot || note.bodySnapshot.trim().length === 0) &&
    (!note.userNote || note.userNote.trim().length === 0) &&
    note.tags.every((tag) => tag.trim().length === 0) &&
    !note.sourceConversationId &&
    !note.sourceMessageId &&
    !note.sourceModelID?.trim() &&
    !note.sourceModelName?.trim() &&
    !note.sourceProviderKind &&
    !note.sourceProviderName?.trim() &&
    !note.sourcePrompt?.trim() &&
    (!note.provenance || note.provenance.length === 0) &&
    !note.isPinned;
}

/** Discard a blank draft created from the list page that was never written to; hard delete, not into the trash. */
export function discardEmptyBlankNote(store: StoreApi<AppStore>, id: string): boolean {
  const note = store.getState().notes.find((candidate) => sameNormalizedID(candidate.id, id));
  if (!note || !isDiscardableEmptyBlankNote(note)) return false;
  store.getState().discardNote(note.id);
  getSyncAdapter()?.didEmptyTrashNotes([note.id]);
  return true;
}

export interface CreateCrosscheckNoteInput {
  conversation: Conversation;
  originMessage: ChatMessage;
  originalPrompt: string;
  originalAnswer: string;
  originProvider: Provider;
  originModel: AIModel;
  crosscheckProvider: Provider;
  crosscheckModel: AIModel;
  crosscheckText: string;
}

function providerDisplaySnapshot(provider: Provider, fallback?: string): string {
  return provider.customName?.trim() || fallback || getProviderDisplayName(provider.kind);
}

/** A cross-check across models, turned into a note that carries provenance for both sources. */
export function createNoteFromCrosscheck(
  store: StoreApi<AppStore>,
  input: CreateCrosscheckNoteInput,
): Note {
  const originProviderName = providerDisplaySnapshot(input.originProvider, input.originMessage.providerName);
  const crosscheckProviderName = providerDisplaySnapshot(input.crosscheckProvider);
  const now = new Date().toISOString();
  const body = [
    '## Original answer',
    '',
    input.originalAnswer.trim(),
    '',
    `## Cross-check (${input.crosscheckModel.name})`,
    '',
    input.crosscheckText.trim(),
  ].join('\n');

  return createNote(store, {
    body,
    bodySnapshot: input.originalAnswer,
    captureKind: 'fullAnswer',
    sourceConversationId: input.conversation.id,
    sourceMessageId: input.originMessage.id,
    sourceModelID: input.originMessage.modelID ?? input.originModel.id,
    sourceModelName: input.originMessage.modelName || input.originModel.name,
    sourceProviderKind: input.originProvider.kind,
    sourceProviderName: originProviderName,
    sourcePrompt: input.originalPrompt,
    provenance: [
      {
        kind: 'origin',
        modelID: input.originMessage.modelID ?? input.originModel.id,
        modelName: input.originMessage.modelName || input.originModel.name,
        providerKind: input.originProvider.kind,
        providerName: originProviderName,
        conversationId: input.conversation.id,
        messageId: input.originMessage.id,
        at: input.originMessage.createdAt ?? now,
      },
      {
        kind: 'crosscheck',
        modelID: input.crosscheckModel.id,
        modelName: input.crosscheckModel.name,
        providerKind: input.crosscheckProvider.kind,
        providerName: crosscheckProviderName,
        conversationId: input.conversation.id,
        messageId: input.originMessage.id,
        at: now,
      },
    ],
  });
}

/** Edit the body. A placeholder title is refreshed to the new first line; a manual title is left alone. */
export function updateNoteBody(store: StoreApi<AppStore>, id: string, body: string): void {
  const note = store.getState().notes.find((n) => sameNormalizedID(n.id, id));
  if (!note) return;
  const now = new Date().toISOString();
  const patch: Partial<Note> = { body, updatedAt: now };
  if (note.titleSource === 'placeholder') {
    patch.title = placeholderTitleFromSource(note.sourcePrompt, body);
  }
  store.getState().updateNote(id, patch);
  getSyncAdapter()?.didUpdateNote(id, {
    body,
    ...(patch.title !== undefined ? { title: patch.title } : {}),
  });
}

/** Replace a note's body and source, keeping the fields the user curated: title, tags, folder, pin and personal note. */
export function replaceNote(store: StoreApi<AppStore>, id: string, input: CreateNoteInput): Note | null {
  const note = store.getState().notes.find((n) => sameNormalizedID(n.id, id));
  if (!note) return null;
  const now = new Date().toISOString();
  const patch: Partial<Note> = {
    body: input.body,
    bodySnapshot: input.bodySnapshot,
    captureKind: input.captureKind,
    sourceConversationId: input.sourceConversationId ? normalizeUUID(input.sourceConversationId) : undefined,
    sourceMessageId: input.sourceMessageId ? normalizeUUID(input.sourceMessageId) : undefined,
    sourceModelID: input.sourceModelID,
    sourceModelName: input.sourceModelName,
    sourceProviderKind: input.sourceProviderKind,
    sourceProviderName: input.sourceProviderName,
    sourcePrompt: input.sourcePrompt,
    provenance: undefined,
    updatedAt: now,
  };
  if (note.titleSource === 'placeholder') {
    patch.title = placeholderTitleFromSource(input.sourcePrompt, input.body);
  }
  store.getState().updateNote(id, patch);
  getSyncAdapter()?.didUpdateNote(id, patch);
  return store.getState().notes.find((n) => sameNormalizedID(n.id, id)) ?? null;
}

/** Rename a note by hand (titleSource becomes 'manual'). */
export function updateNoteTitle(store: StoreApi<AppStore>, id: string, title: string): void {
  const trimmed = title.trim();
  store.getState().updateNote(id, { title: trimmed, titleSource: 'manual', updatedAt: new Date().toISOString() });
  getSyncAdapter()?.didUpdateNote(id, { title: trimmed, titleSource: 'manual' });
}

/** Edit the user's personal note attached to a note. */
export function updateNoteUserNote(store: StoreApi<AppStore>, id: string, userNote: string): void {
  store.getState().updateNote(id, { userNote, updatedAt: new Date().toISOString() });
  getSyncAdapter()?.didUpdateNote(id, { userNote });
}

/** Set tags. */
export function updateNoteTags(store: StoreApi<AppStore>, id: string, tags: string[]): void {
  store.getState().updateNote(id, { tags, updatedAt: new Date().toISOString() });
  getSyncAdapter()?.didUpdateNote(id, { tags });
}

/** Toggle the pin. */
export function toggleNotePin(store: StoreApi<AppStore>, id: string): void {
  const note = store.getState().notes.find((n) => sameNormalizedID(n.id, id));
  if (!note) return;
  const isPinned = !note.isPinned;
  store.getState().updateNote(id, { isPinned, updatedAt: new Date().toISOString() });
  getSyncAdapter()?.didUpdateNote(id, { isPinned });
}

/** Soft delete a note into the trash; the remote copy records a deletedAt tombstone. */
export function deleteNote(store: StoreApi<AppStore>, id: string): void {
  const now = new Date().toISOString();
  store.getState().removeNote(id, now);
  getSyncAdapter()?.didDeleteNotes([id]);
}

/** Restore from the trash: clear the deletedAt tombstone and bump updatedAt. */
export function restoreNote(store: StoreApi<AppStore>, id: string): void {
  const now = new Date().toISOString();
  // Only emit the restore sync while the note is still in the trash, so delete -> empty trash -> undo cannot resurrect a document that was already hard deleted remotely.
  const inTrash = store.getState().trashedNotes.some((n) => sameNormalizedID(n.id, id));
  store.getState().restoreNote(id, now);
  if (inTrash) getSyncAdapter()?.didRestoreNote(id);
}

/** Emptying the trash promotes soft deletes to hard deletes: IDB is reconciled by the subscriber union and the remote document is deleted. */
export function emptyTrash(store: StoreApi<AppStore>): void {
  const ids = store.getState().trashedNotes.map((n) => n.id);
  if (ids.length === 0) return;
  store.getState().emptyTrash();
  getSyncAdapter()?.didEmptyTrashNotes(ids);
}

/** Move a note into a folder; folderID = null moves it out. */
export function moveNoteToFolder(store: StoreApi<AppStore>, id: string, folderID: string | null): void {
  store.getState().updateNote(id, { noteFolderID: folderID ?? undefined, updatedAt: new Date().toISOString() });
  getSyncAdapter()?.didMoveNoteToFolder(id, folderID);
}

/* ── NoteFolder operations ──────────────────────────────────── */

/** Create a note folder using gap-based sortOrder with a step of 1000. Returns null when the name is blank. */
export function createNoteFolder(store: StoreApi<AppStore>, name: string, colorTag?: string): NoteFolder | null {
  const trimmed = name.trim().slice(0, 30);
  if (!trimmed) return null;

  const { noteFolders } = store.getState();
  const sortOrder = noteFolders.length === 0
    ? 1000
    : Math.max(...noteFolders.map((f) => f.sortOrder)) + 1000;

  const now = new Date().toISOString();
  const folder: NoteFolder = {
    id: createCanonicalUUID(),
    name: trimmed,
    sortOrder,
    colorTag,
    createdAt: now,
    updatedAt: now,
  };

  store.getState().addNoteFolder(folder);
  getSyncAdapter()?.didCreateNoteFolder(folder);
  return folder;
}

/** Rename a note folder. */
export function renameNoteFolder(store: StoreApi<AppStore>, id: string, name: string): void {
  const trimmed = name.trim().slice(0, 30);
  if (!trimmed) return;
  store.getState().updateNoteFolder(id, { name: trimmed, updatedAt: new Date().toISOString() });
  getSyncAdapter()?.didUpdateNoteFolder(id, { name: trimmed });
}

/** Change a note folder's colour tag. */
export function updateNoteFolderColor(store: StoreApi<AppStore>, id: string, colorTag: string): void {
  store.getState().updateNoteFolder(id, { colorTag, updatedAt: new Date().toISOString() });
  getSyncAdapter()?.didUpdateNoteFolder(id, { colorTag });
}

/** Soft delete a note folder and cascade-clear noteFolderID on the affected notes, trash included. */
export function deleteNoteFolder(store: StoreApi<AppStore>, id: string): void {
  const state = store.getState();
  const affectedNoteIds = [...state.notes, ...state.trashedNotes]
    .filter((n) => n.noteFolderID === id)
    .map((n) => n.id);
  state.removeNoteFolder(id);
  getSyncAdapter()?.didDeleteNoteFolder(id, affectedNoteIds);
}

/** Reorder note folders by drag; when adjacent gaps shrink to 1 or less the whole list is renumbered with a step of 1000. */
export function reorderNoteFolders(store: StoreApi<AppStore>, reordered: NoteFolder[]): void {
  const needsRebalance = reordered.some((f, i) => i > 0 && f.sortOrder - reordered[i - 1].sortOrder <= 1);
  let next = reordered;
  if (needsRebalance) {
    const now = new Date().toISOString();
    next = reordered.map((f, i) => ({ ...f, sortOrder: (i + 1) * 1000, updatedAt: now }));
  }
  store.getState().reorderNoteFolders(next);
  getSyncAdapter()?.didReorderNoteFolders(next);
}
