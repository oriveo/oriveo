import type { Attachment, ChatMessage, Conversation, Note, NoteFolder, Provider, ProviderKind } from '@oriveo/shared';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function normalizeUUID(id: string): string {
  return UUID_RE.test(id) ? id.toUpperCase() : id;
}

export function createCanonicalUUID(): string {
  return normalizeUUID(crypto.randomUUID());
}

/* ── Deterministic provider ID (UUIDv5) ─────────────────────────
 * The first, default instance of an official provider uses a deterministic id: two clients adding
 * the same official provider derive the same docId, so the remote write merges instead of
 * leaving a duplicate per client.
 * Additional instances (isAdditionalInstance=true) still get a random createCanonicalUUID().
 * Relay connections do not take part.
 */

// NS = UUIDv5(DNS, "oriveo.provider.identity"), the same constant hard-coded on every client.
// 16 big-endian bytes: 9A 11 95 DE 3A F9 58 88 AB C8 B8 17 7C 45 8C 07
const PROVIDER_ID_NAMESPACE = new Uint8Array([
  0x9a, 0x11, 0x95, 0xde, 0x3a, 0xf9, 0x58, 0x88,
  0xab, 0xc8, 0xb8, 0x17, 0x7c, 0x45, 0x8c, 0x07,
]);

/**
 * Map a web enum string to the canonical kind string used when deriving an id.
 * Two web enum values carry an `AI` suffix and have to be mapped to the shared string before the
 * id is computed: togetherAI -> together, fireworksAI -> fireworks.
 * For every other kind the rawValue is already canonical.
 */
export function canonicalProviderKindForId(kind: ProviderKind | string): string {
  switch (kind) {
    case 'togetherAI':
      return 'together';
    case 'fireworksAI':
      return 'fireworks';
    default:
      return kind;
  }
}

/**
 * Deterministic provider id = UUIDv5(NS, "{canonicalKind}|{regionId}"), uppercased.
 * SHA-1 is computed by hand with version=5 / variant=RFC4122 set explicitly; v3/MD5 is not valid
 * here. The result goes through a normalizeUUID round-trip so it matches docId and mergeKey.
 *
 * @param kind web ProviderKind enum string, mapped to canonical internally
 * @param regionId region option id; pass "" for providers that have no region
 */
export async function createDeterministicProviderId(
  kind: ProviderKind | string,
  regionId: string,
): Promise<string> {
  // SiliconFlow China derives its id with an empty region, so folding cn -> "" keeps existing
  // China users on their original docId; the international region keeps intl and gets its own identity.
  const identityRegionId = kind === 'siliconFlow' && regionId === 'cn' ? '' : regionId;
  const name = `${canonicalProviderKindForId(kind)}|${identityRegionId}`;
  const nameBytes = new TextEncoder().encode(name);

  const message = new Uint8Array(PROVIDER_ID_NAMESPACE.length + nameBytes.length);
  message.set(PROVIDER_ID_NAMESPACE, 0);
  message.set(nameBytes, PROVIDER_ID_NAMESPACE.length);

  const digest = new Uint8Array(
    await crypto.subtle.digest('SHA-1', message as Uint8Array<ArrayBuffer>),
  );
  const bytes = digest.slice(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x50; // version 5
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xxxxxx

  const hex = Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
  const uuid = `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  return normalizeUUID(uuid);
}

export function sameNormalizedID(a: string | null | undefined, b: string | null | undefined): boolean {
  if (!a || !b) return a === b;
  return normalizeUUID(a) === normalizeUUID(b);
}

export function normalizeAttachmentIDs(attachment: Attachment): Attachment {
  return {
    ...attachment,
    id: normalizeUUID(attachment.id),
    localImageID: attachment.localImageID ? normalizeUUID(attachment.localImageID) : attachment.localImageID,
  };
}

export function normalizeMessageIDs(message: ChatMessage): ChatMessage {
  return {
    ...message,
    id: normalizeUUID(message.id),
    providerID: message.providerID ? normalizeUUID(message.providerID) : message.providerID,
    attachments: message.attachments?.map(normalizeAttachmentIDs),
  };
}

export function normalizePinnedNoteIDs(ids: readonly string[] | undefined, limit = 3): string[] {
  const normalized: string[] = [];
  const seen = new Set<string>();
  for (const raw of ids ?? []) {
    const id = normalizeUUID(raw.trim());
    if (!id || seen.has(id)) continue;
    seen.add(id);
    normalized.push(id);
  }
  // Over the limit, keep the last `limit` entries so the most recently pinned notes survive
  return normalized.slice(-limit);
}

export function normalizeConversationIDs(conversation: Conversation): Conversation {
  const pinnedNoteIds = normalizePinnedNoteIDs(conversation.pinnedNoteIds);
  return {
    ...conversation,
    id: normalizeUUID(conversation.id),
    providerID: normalizeUUID(conversation.providerID),
    folderID: conversation.folderID ? normalizeUUID(conversation.folderID) : conversation.folderID,
    messages: conversation.messages.map(normalizeMessageIDs),
    ...(pinnedNoteIds.length > 0 ? { pinnedNoteIds } : { pinnedNoteIds: undefined }),
  };
}

export function normalizeProviderIDs(provider: Provider): Provider {
  return {
    ...provider,
    id: normalizeUUID(provider.id),
  };
}

export function dedupeProvidersByID(providers: Provider[]): Provider[] {
  const byID = new Map<string, Provider>();

  for (const provider of providers.map(normalizeProviderIDs)) {
    const key = normalizeUUID(provider.id);
    const existing = byID.get(key);
    if (!existing) {
      byID.set(key, provider);
      continue;
    }

    const existingScore = existing.models.length + existing.catalogModels.length;
    const nextScore = provider.models.length + provider.catalogModels.length;
    byID.set(key, nextScore >= existingScore ? provider : existing);
  }

  return [...byID.values()];
}

export function normalizeNoteIDs(note: Note): Note {
  return {
    ...note,
    id: normalizeUUID(note.id),
    noteFolderID: note.noteFolderID ? normalizeUUID(note.noteFolderID) : note.noteFolderID,
    sourceConversationId: note.sourceConversationId ? normalizeUUID(note.sourceConversationId) : note.sourceConversationId,
    sourceMessageId: note.sourceMessageId ? normalizeUUID(note.sourceMessageId) : note.sourceMessageId,
  };
}

export function normalizeNoteFolderIDs(folder: NoteFolder): NoteFolder {
  return {
    ...folder,
    id: normalizeUUID(folder.id),
  };
}

/** Deduplicate notes by id, case-insensitively; for the same id keep the newer updatedAt (notes have no messages, so time is the only criterion). */
export function dedupeNotesByID(notes: Note[]): Note[] {
  const byID = new Map<string, Note>();

  for (const note of notes.map(normalizeNoteIDs)) {
    const key = normalizeUUID(note.id);
    const existing = byID.get(key);
    if (!existing) {
      byID.set(key, note);
      continue;
    }

    const existingTime = Date.parse(existing.updatedAt ?? '') || 0;
    const nextTime = Date.parse(note.updatedAt ?? '') || 0;
    byID.set(key, nextTime >= existingTime ? note : existing);
  }

  return [...byID.values()];
}

export function dedupeConversationsByID(conversations: Conversation[]): Conversation[] {
  const byID = new Map<string, Conversation>();

  for (const conversation of conversations.map(normalizeConversationIDs)) {
    const key = normalizeUUID(conversation.id);
    const existing = byID.get(key);
    if (!existing) {
      byID.set(key, conversation);
      continue;
    }

    const existingTime = Date.parse(existing.updatedAt ?? '') || 0;
    const nextTime = Date.parse(conversation.updatedAt ?? '') || 0;
    const pickNext = conversation.messages.length > existing.messages.length ||
      (conversation.messages.length === existing.messages.length && nextTime >= existingTime);

    byID.set(key, pickNext ? conversation : existing);
  }

  return [...byID.values()];
}
