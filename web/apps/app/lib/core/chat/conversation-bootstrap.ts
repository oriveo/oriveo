import type { ChatMessage, Conversation } from '@oriveo/shared';
import { tryGetVanillaStore } from '../../../providers/StoreProvider';
import { getConversationById } from '../../infra/storage/idb';
import { getActiveUIDSync } from '../../infra/storage/partition';
import { loadSyncCore } from '../sync-lazy';
import { normalizeUUID, sameNormalizedID } from '../../utils/id-utils';

const inflightConversationWarmups = new Map<string, Promise<Conversation | undefined>>();
const inflightAnchorWarmups = new Map<string, Promise<Conversation | undefined>>();

// Conversation load state is decided by the priority chain in chat-load-state.ts.
// That chain deliberately does not depend on remoteMessageCount/previewText: both fields can be
// missing or lag behind when they sync from another device, so they cannot be guessed from.
// Whether history exists is decided by the number of rows an on-demand read-only backfill
// actually returns.

export async function warmConversationInStore(
  conversationId: string,
): Promise<Conversation | undefined> {
  const store = tryGetVanillaStore();
  if (!store) return undefined;

  const state = store.getState();
  const existing = state.conversations.find((item) => sameNormalizedID(item.id, conversationId));
  if (existing?.messages.length) {
    return existing;
  }

  const requestKey = conversationId.trim().toLowerCase();
  const inFlight = inflightConversationWarmups.get(requestKey);
  if (inFlight) return inFlight;

  // Partition gate: the uid used for writing must be the one captured when the read started. If
  // the user signs out or switches accounts while the IDB read is in flight, the late .then would
  // write the previous partition's conversations, messages included, into the new partition's
  // store. Persistence subscribers only guard against "scheduled before the switch, stored after
  // it" and cannot stop a store write that happens entirely after the switch.
  const expectedUID = getActiveUIDSync();
  const request = getConversationById(conversationId, expectedUID)
    .then((fullConversation) => {
      if (!fullConversation) return undefined;
      if (getActiveUIDSync() !== expectedUID) return undefined;

      const nextState = store.getState();
      const exists = nextState.conversations.some((item) => sameNormalizedID(item.id, conversationId));
      if (exists) {
        nextState.updateConversation(conversationId, fullConversation);
      } else {
        nextState.addConversation(fullConversation);
      }
      return fullConversation;
    })
    .finally(() => {
      inflightConversationWarmups.delete(requestKey);
    });

  inflightConversationWarmups.set(requestKey, request);
  return request;
}

function conversationHasMessage(conversation: Conversation | undefined, messageId: string | undefined): boolean {
  if (!conversation || !messageId) return false;
  return conversation.messages.some((message) => sameNormalizedID(message.id, messageId));
}

export function mergeMessagesIntoConversation(
  conversation: Conversation,
  incoming: ChatMessage[],
): Conversation {
  if (incoming.length === 0) return conversation;

  const merged = [...conversation.messages];
  for (const message of incoming) {
    const index = merged.findIndex((candidate) => sameNormalizedID(candidate.id, message.id));
    if (index === -1) {
      merged.push(message);
    } else {
      merged[index] = { ...merged[index], ...message };
    }
  }

  merged.sort((a, b) => {
    const aTime = a.createdAt ? new Date(a.createdAt).getTime() : 0;
    const bTime = b.createdAt ? new Date(b.createdAt).getTime() : 0;
    return aTime - bTime;
  });

  return { ...conversation, messages: merged };
}

export async function warmConversationAnchorInStore(
  conversationId: string,
  messageId?: string | null,
): Promise<Conversation | undefined> {
  const normalizedConversationId = normalizeUUID(conversationId);
  const normalizedMessageId = messageId ? normalizeUUID(messageId) : messageId;
  const store = tryGetVanillaStore();
  if (!store) return undefined;
  if (!normalizedMessageId) return warmConversationInStore(normalizedConversationId);

  const state = store.getState();
  const existing = state.conversations.find((item) => sameNormalizedID(item.id, normalizedConversationId));
  if (conversationHasMessage(existing, normalizedMessageId)) return existing;

  const requestKey = `${normalizedConversationId.trim().toLowerCase()}:${normalizedMessageId.trim().toLowerCase()}`;
  const inFlight = inflightAnchorWarmups.get(requestKey);
  if (inFlight) return inFlight;

  // Partition gate: fetching a window through the port can take a network round trip of seconds, so
  // the partition must be rechecked before writing to the store.
  const expectedUID = getActiveUIDSync();
  const request = (async () => {
    const warmed = await warmConversationInStore(normalizedConversationId);
    if (conversationHasMessage(warmed, normalizedMessageId)) return warmed;

    const { getSyncAdapter } = await loadSyncCore();
    const adapter = getSyncAdapter();
    if (!adapter?.fetchMessageWindowAround) return warmed;

    const fetched = await adapter.fetchMessageWindowAround(
      normalizedConversationId,
      normalizedMessageId,
      { before: 30, after: 30 },
    );
    if (fetched.length === 0) return warmed;
    if (getActiveUIDSync() !== expectedUID) return undefined;

    const nextState = store.getState();
    const current = nextState.conversations.find((item) => sameNormalizedID(item.id, normalizedConversationId));
    if (!current) return warmed;

    const merged = mergeMessagesIntoConversation(current, fetched);
    nextState.updateConversation(current.id, { messages: merged.messages });
    return merged;
  })().catch(() => undefined)
    .finally(() => {
      inflightAnchorWarmups.delete(requestKey);
    });

  inflightAnchorWarmups.set(requestKey, request);
  return request;
}
