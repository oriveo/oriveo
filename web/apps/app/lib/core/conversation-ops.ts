/**
 * Conversation operations: a single transaction across the store and sync.
 */

import type { StoreApi } from 'zustand';
import type { Conversation } from '@oriveo/shared';
import type { AppStore } from './store/app-store';
import { deleteAttachments, flushPendingConversationDeletions, getSyncAdapter } from './sync-port';
import { createCanonicalUUID, normalizePinnedNoteIDs, normalizeUUID, sameNormalizedID } from '../utils/id-utils';
import { flushAndInterruptStream, hasStream } from './chat/active-streams';
import { trackEvent } from './telemetry';
import { getActiveUID } from '../infra/storage/partition';
import { withErrorReporting } from '../sentry/report-silent';
import { countNotesReferencingConversation } from './notes/source-link';


import { removeGenerationParameterScopes } from './chat/generation-parameter-settings';
import { deleteLocalConversationContinuation } from './chat/continuation-lifecycle';

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
