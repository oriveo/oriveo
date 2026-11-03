/**
 * Conversation operations: a single transaction across the store and sync.
 */

import type { StoreApi } from 'zustand';
import { conversationSkillFields, conversationSkillIds, type Conversation } from '@oriveo/shared';
import type { AppStore } from './store/app-store';
import { normalizeConversationInstructions } from '@oriveo/core/context/conversation-instructions';
import { parseBudgetCap, type BudgetCapOption } from '@oriveo/core/context/budget';
import { deleteAttachments, flushPendingConversationDeletions, getSyncAdapter } from './sync-port';
import { createCanonicalUUID, normalizePinnedNoteIDs, normalizeUUID, sameNormalizedID } from '../utils/id-utils';
import { flushAndInterruptStream, hasStream } from './chat/active-streams';
import { trackEvent } from './telemetry';
import { getActiveUID } from '../infra/storage/partition';
import { withErrorReporting } from '../sentry/report-silent';
import { countNotesReferencingConversation } from './notes/source-link';


import { removeGenerationParameterScopes } from './chat/generation-parameter-settings';
import { removeAdditionalBodyScopes } from './chat/additional-body-settings';
import { deleteLocalConversationContinuation } from './chat/continuation-lifecycle';

// Skill id list caps; local copy of the Unicode-whitespace trim used by the skill id list normalizer.
const SKILL_IDS_MAX = 3;
const DISABLED_AUTO_SKILL_IDS_MAX = 30;
const SKILL_EDGE_WS_RE = /^[\u0009-\u000D\u0020\u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]+|[\u0009-\u000D\u0020\u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]+$/gu;

/** Skill id list: string items only, trimmed + normalizeUUID, deduplicated in order, first `max`. */
function normalizeSkillIdList(value: unknown, max: number): string[] {
  const out: string[] = [];
  for (const raw of Array.isArray(value) ? value : []) {
    if (typeof raw !== 'string') continue;
    const id = normalizeUUID(raw.replace(SKILL_EDGE_WS_RE, ''));
    if (id && !out.includes(id)) out.push(id);
  }
  return out.slice(0, max);
}

function computeConversationAgeHours(conv: Conversation | undefined): number {
  if (!conv?.createdAt) return 0;
  const created = Date.parse(conv.createdAt);
  if (Number.isNaN(created)) return 0;
  return Math.max(0, Math.round((Date.now() - created) / 3_600_000));
}

/**
 * A conversation's active stream must be aborted and marked interrupted before the conversation is
 * deleted. Otherwise the conversation is removed from the store while sessions, streamingTexts and
 * streamingConversationIds still hold the abort handle and the partial, leaving the stream running
 * and the partial growing.
 */
export function deleteConversation(store: StoreApi<AppStore>, convId: string) {
  const conv = store.getState().conversations.find((c) => c.id === convId);
  if (hasStream(convId)) flushAndInterruptStream(convId);
  deleteConversationAttachments(conv);
  store.getState().removeConversation(convId);
  removeGenerationParameterScopes({ conversationId: convId });
  removeAdditionalBodyScopes({ conversationId: convId });
  deleteLocalConversationContinuation(convId);
  // The delete intent is queued in IDB and replayed, and only cleared once acknowledged. Calling
  // didDeleteConversations directly silently dropped the delete whenever the adapter was null,
  // which is the case until bootstrap has hydrated the store.
  void flushPendingConversationDeletions([convId]);
  trackEvent('conversation_deleted', {
    conversation_id: convId,
    message_count: conv?.messages.length ?? 0,
    age_hours: computeConversationAgeHours(conv),
    bulk: false,
  });
}

export function getConversationNoteReferenceCount(store: StoreApi<AppStore>, convId: string): number {
  return countNotesReferencingConversation(store.getState().notes, convId);
}

export function deleteConversations(store: StoreApi<AppStore>, ids: string[]) {
  const convs = store.getState().conversations.filter((c) => ids.includes(c.id));
  deleteConversationAttachments(...convs);
  for (const id of ids) {
    if (hasStream(id)) flushAndInterruptStream(id);
    store.getState().removeConversation(id);
    removeGenerationParameterScopes({ conversationId: id });
    removeAdditionalBodyScopes({ conversationId: id });
    deleteLocalConversationContinuation(id);
  }
  // Same as above: queue and replay, so a delete is not silently lost while the adapter is not ready (batch delete hit exactly this)
  void flushPendingConversationDeletions(ids);
  for (const conv of convs) {
    trackEvent('conversation_deleted', {
      conversation_id: conv.id,
      message_count: conv.messages.length,
      age_hours: computeConversationAgeHours(conv),
      bulk: ids.length > 1,
    });
  }
}

function deleteConversationAttachments(...convs: Array<Conversation | undefined>): void {
  const refs = convs.flatMap((conv) =>
    conv?.messages.flatMap((msg) => msg.attachments?.map((att) => att.storageRef).filter((ref): ref is string => Boolean(ref)) ?? []) ?? [],
  );
  const uniqueRefs = Array.from(new Set(refs));
  if (uniqueRefs.length === 0) return;
  getActiveUID().then((uid) => {
    if (uid === 'guest') return;
    return deleteAttachments(uid, uniqueRefs);
  }).catch(withErrorReporting('attachments.deleteOnConversationDelete'));
}

export function updateConversationTitle(store: StoreApi<AppStore>, convId: string, title: string) {
  store.getState().updateConversation(convId, {
    title: title.trim(),
    hasCustomTitle: true,
  });
  getSyncAdapter()?.didUpdateConversationTitle(convId, title.trim());
}

/** Per-conversation "use memory" switch: update the store (the subscriber persists it to IDB) and notify the sync adapter, the same path as renaming. */
export function updateConversationUseMemory(store: StoreApi<AppStore>, convId: string, useMemory: boolean) {
  store.getState().setConversationUseMemory(convId, useMemory);
  getSyncAdapter()?.didUpdateConversationUseMemory(convId, useMemory);
}

/** Conversation instructions: normalize, update the store (the subscriber persists to IDB) and notify the sync adapter; an empty string clears them. */
export function updateConversationInstructions(store: StoreApi<AppStore>, convId: string, instructions: string) {
  const normalized = normalizeConversationInstructions(instructions);
  const conv = store.getState().conversations.find((c) => sameNormalizedID(c.id, convId));
  // Conversation missing or value unchanged: skip the write and the adapter notification (a merge write would create a partial document and needlessly bump metadataUpdatedAt)
  if (!conv || (conv.instructions ?? '') === normalized) return;
  store.getState().updateConversation(convId, { instructions: normalized });
  getSyncAdapter()?.didUpdateConversationInstructions(convId, normalized);
}

/**
 * Per-conversation context cap: undefined follows the global setting (the field is removed from the object); any other value goes through parseBudgetCap first and returns false if it cannot be parsed.
 * Only contextCap changes, updatedAt is untouched; returns false without notifying the adapter when the conversation is missing or the value is unchanged.
 */
export function updateConversationContextCap(
  store: StoreApi<AppStore>,
  convId: string,
  cap: BudgetCapOption | undefined,
): boolean {
  const next = cap === undefined ? null : parseBudgetCap(cap);
  // Only undefined means follow-global; an unparseable value is rejected outright, with no change and no notification
  if (cap !== undefined && next === null) return false;
  const conv = store.getState().conversations.find((c) => sameNormalizedID(c.id, convId));
  if (!conv || (conv.contextCap ?? null) === next) return false;
  store.setState((s) => ({
    conversations: s.conversations.map((c) => {
      if (!sameNormalizedID(c.id, convId)) return c;
      const { contextCap: _previous, ...rest } = c;
      return next === null ? rest : { ...rest, contextCap: next };
    }),
  }));
  getSyncAdapter()?.didUpdateConversationContextCap(convId, next ?? undefined);
  return true;
}

export function updateConversationModel(
  store: StoreApi<AppStore>,
  convId: string,
  modelId: string,
  providerId: string,
) {
  // providerKind is required on Conversation, so a missing provider fails fast: list icons render
  // with no fallback and dirty rows must not reach storage. Callers must ensure the provider exists.
  let provider = store.getState().providers.find((p) => sameNormalizedID(p.id, providerId));
  // a user-owned provider is a purely runtime virtual provider, merged into runtimeProviders and never written
  // to store.providers, so switching an existing conversation to a free model resolves through the
  // runtime cache rather than failing fast; the providerKind contract still holds.
  if (!provider && sameNormalizedID(providerId, '')) {
    provider = undefined;
  }
  if (!provider && sameNormalizedID(providerId, '')) {
    provider = undefined;
  }
  if (!provider) {
    throw new Error(`updateConversationModel: provider not found (id=${providerId})`);
  }
  const relayKind = provider.kind === 'relay' ? provider.relayKind ?? null : null;
  store.getState().updateConversation(convId, {
    modelID: modelId,
    providerID: providerId,
    providerKind: provider.kind,
    relayKind: relayKind ?? undefined,
  });
  getSyncAdapter()?.didUpdateConversationModel(convId, modelId, providerId, provider.kind, relayKind);
}

export function pinNoteToConversation(store: StoreApi<AppStore>, convId: string, noteId: string): boolean {
  const conv = store.getState().conversations.find((candidate) => sameNormalizedID(candidate.id, convId));
  if (!conv) return false;
  const current = conv.pinnedNoteIds ?? [];
  const normalizedNoteId = normalizeUUID(noteId.trim());
  if (!normalizedNoteId) return false;
  if (current.some((id) => sameNormalizedID(id, normalizedNoteId))) return false;
  const next = [
    ...normalizePinnedNoteIDs(current).filter((id) => !sameNormalizedID(id, normalizedNoteId)),
    normalizedNoteId,
  ].slice(-3);
  store.getState().updateConversation(convId, { pinnedNoteIds: next });
  getSyncAdapter()?.didUpdateConversationPinnedNotes(convId, next);
  return true;
}

/**
 * Turn a skill off for automatic use in this conversation: appended once to disabledAutoSkillIds
 * (oldest dropped beyond the cap), then single-key merge to the cloud like pinnedNoteIds.
 */
export function disableAutoSkill(store: StoreApi<AppStore>, convId: string, skillId: string): boolean {
  const conv = store.getState().conversations.find((candidate) => sameNormalizedID(candidate.id, convId));
  if (!conv) return false;
  const [normalizedSkillId] = normalizeSkillIdList([skillId], 1);
  if (!normalizedSkillId) return false;
  const current = normalizeSkillIdList(conv.disabledAutoSkillIds, Number.MAX_SAFE_INTEGER);
  if (current.includes(normalizedSkillId)) return false;
  const next = [...current, normalizedSkillId].slice(-DISABLED_AUTO_SKILL_IDS_MAX);
  store.getState().updateConversation(convId, { disabledAutoSkillIds: next });
  return true;
}

/**
 * Replace the conversation's attached skills (composer chips): normalized, at most SKILL_IDS_MAX, dual-written
 * with the legacy skillId through conversationSkillFields, then single-key merge to the cloud. No-op when unchanged.
 */
export function setConversationSkillIds(store: StoreApi<AppStore>, convId: string, skillIds: readonly string[]): boolean {
  const conv = store.getState().conversations.find((candidate) => sameNormalizedID(candidate.id, convId));
  if (!conv) return false;
  const next = normalizeSkillIdList(skillIds, SKILL_IDS_MAX);
  const current = normalizeSkillIdList(conversationSkillIds(conv), SKILL_IDS_MAX);
  if (next.length === current.length && next.every((id, index) => id === current[index])) return false;
  store.getState().updateConversation(conv.id, conversationSkillFields(next));
  return true;
}

export function unpinNoteFromConversation(store: StoreApi<AppStore>, convId: string, noteId: string): boolean {
  const conv = store.getState().conversations.find((candidate) => sameNormalizedID(candidate.id, convId));
  if (!conv) return false;
  const current = conv.pinnedNoteIds ?? [];
  if (!current.some((id) => sameNormalizedID(id, noteId))) return false;
  const next = normalizePinnedNoteIDs(current.filter((id) => !sameNormalizedID(id, noteId)));
  store.getState().updateConversation(convId, { pinnedNoteIds: next });
  getSyncAdapter()?.didUpdateConversationPinnedNotes(convId, next);
  return true;
}

/**
 * Copies a conflict copy into a new, editable conversation.
 * - fresh id, conflict marker prefix stripped, copy flag cleared
 * - messages are kept as they are, including their ChatMessage ids, so the user can continue asking
 * - returns the new conversation id so the caller can route to it
 *
 * Cloud sync follows the usual convention: a conversation is pushed by didSendMessage once the user
 * actually sends a message. `didCreateConversation` is not called here, because the adapter has no
 * such method.
 */
export function cloneConversationFromConflictCopy(
  store: StoreApi<AppStore>,
  conflictCopy: Conversation,
): string {
  const newId = createCanonicalUUID();
  const now = new Date().toISOString();
  const cleanTitle = (conflictCopy.title ?? '').replace(/^🔀\s*/, '') || 'Untitled';

  // messages are deep-copied and attachments.storageRef is cleared, so the new conversation does not
  // share cloud attachment pointers with the conflict copy. Deleting that copy later triggers
  // deleteConversationAttachments, which removes the cloud object and would leave the new
  // conversation holding a dangling storageRef. With it cleared, attachment-sync uploads a fresh
  // independent object on the first send, and the local base64 / data URI keeps the image visible.
  const clonedMessages = conflictCopy.messages.map((msg) => ({
    ...msg,
    attachments: msg.attachments?.map((att) => ({ ...att, storageRef: undefined })),
  }));

  const cloned: Conversation = {
    ...conflictCopy,
    id: newId,
    title: cleanTitle,
    messages: clonedMessages,
    isConflictCopy: false,
    conflictOriginId: undefined,
    isDraft: false,
    draftText: '',
    updatedAt: now,
    createdAt: now,
    firestoreUpdatedAt: undefined,
    firestoreMetadataUpdatedAt: undefined,
  };

  store.getState().addConversation(cloned);
  return newId;
}

/** Removes every conflict copy, both locally and in the cloud. */
export function cleanupConflictCopies(store: StoreApi<AppStore>): number {
  const ids = store.getState().conversations
    .filter((c) => c.isConflictCopy === true)
    .map((c) => c.id);
  if (ids.length === 0) return 0;
  deleteConversations(store, ids);
  return ids.length;
}
