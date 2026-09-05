import * as Sentry from '@sentry/nextjs';
import type { StoreApi } from 'zustand';
import type { AppStore } from './app-store';
import type { Conversation, Provider, Note } from '@oriveo/shared';
import {
  putConversationsBatch,
  getAllProviders,
  getAllConversations,
  getAllFolders,
  getAllNotes,
  getAllNoteFolders,
  getSessionValue,
} from '../../infra/storage/idb';
import { getPreference, setPreference } from '../../infra/storage/preferences';
import type { AppPreference, LastUsedModelRef } from '@oriveo/shared';
import { dedupeConversationsByID, dedupeNotesByID, dedupeProvidersByID } from '../../utils/id-utils';
import { deduplicateByCanonical, enrichStoredModel } from '../providers/catalog-model';
import { initMetadata } from '../metadata/metadata-client';
import { assignFolderColors } from '../folder-ops';
import { readStreamPartialBackup, clearStreamPartialBackup } from './stream-partial-backup';
import {
  subscribeProviders,
  subscribeConversations,
  subscribePreferences,
  subscribeOnboarding,
  subscribePinned,
  subscribeConversationOrder,
  subscribeLastUsedModelRef,
  subscribeFolders,
  subscribeNotes,
  subscribeNoteFolders,
} from './persistence-subscribers';
import { getActiveUIDSync } from '../../infra/storage/partition';
import { beginCapabilityEvidenceIdentitiesForLoadedProviders } from '../providers/capability-evidence-identity';

function recoverPersistedProviderStatus(provider: Provider): Provider {
  return provider.status.kind === 'syncing'
    ? { ...provider, status: { kind: 'connected' } }
    : provider;
}

function toConversationSummary(conversation: Conversation): Conversation {
  // Backfill for older records: providerKind is a newer redundant field that older IDB
  // records lack. During hydrate, before messages are cleared, it is extracted from the
  // last assistant message and written back, so sidebar icon rendering no longer depends
  // on providers.find() and orphaned or unsynced conversations still show one.
  // The scan stops at the first matching assistant, so it is amortized O(1). relayKind
  // has no source to recover from on old records; the write path fills it in on the next
  // sendMessage or provider switch.
  let providerKind = conversation.providerKind;
  if (!providerKind) {
    for (let i = conversation.messages.length - 1; i >= 0; i--) {
      const msg = conversation.messages[i];
      if (msg.role === 'assistant' && msg.providerKind) {
        providerKind = msg.providerKind;
        break;
      }
    }
  }
  return {
    ...conversation,
    remoteMessageCount: Math.max(conversation.remoteMessageCount ?? 0, conversation.messages.length),
    messages: [],
    ...(providerKind ? { providerKind } : {}),
  };
}

/* ── Hydrate: load persisted data into store ─────────── */

export async function hydrateStore(store: StoreApi<AppStore>, expectedUID?: string): Promise<void> {
  try {
    assertExpectedHydrationUID(expectedUID);
    const [providers, rawConversations, folders, rawNotes, rawNoteFolders, lastUsedModelRef] = await Promise.all([
      getAllProviders(expectedUID),
      getAllConversations(expectedUID),
      getAllFolders(expectedUID),
      getAllNotes(expectedUID),
      getAllNoteFolders(expectedUID),
      getSessionValue<LastUsedModelRef | null>('lastUsedModelRef', expectedUID),
    ]);
    assertExpectedHydrationUID(expectedUID);

    // Split notes by deletedAt: active ones into notes, tombstones into trashedNotes,
    // which is the trash data source. One setState, so the trash is not empty after a refresh.
    const allNotes = dedupeNotesByID(rawNotes);
    const notes: Note[] = [];
    const trashedNotes: Note[] = [];
    for (const note of allNotes) {
      (note.deletedAt ? trashedNotes : notes).push(note);
    }
    // Only active note folders are stored locally (soft-delete tombstones live remotely); defensively drop any tombstoned rows.
    const noteFolders = rawNoteFolders.filter((f) => !f.deletedAt);

    // Clear generating state left behind by a dropped connection or a crash, turning it into interrupted.
    // Also merge the sessionStorage backup map: the partial written from the synchronous pagehide
    // context can be longer than the text in IDB, whose async transaction had not committed yet.
    // Take whichever is longer. Each conversation has its own backup, keyed by convId.
    const backupMap = readStreamPartialBackup();
    const hasAnyBackup = Object.keys(backupMap).length > 0;
    const conversationsToWriteBack: Conversation[] = [];
    const sanitizedConversations = rawConversations.map((conv) => {
      const hasStuckMsg = conv.messages.some((m) => m.state === 'generating');
      const backup = backupMap[conv.id];
      if (!hasStuckMsg && !backup) return conv;
      const updatedMessages = conv.messages.map((m) => {
        let text = m.text;
        const backupMatchesMessage = backup && m.id === backup.msgId;
        if (backup && m.id === backup.msgId && backup.partial.length > (m.text?.length ?? 0)) {
          text = backup.partial;
        }
        const managedFields = backupMatchesMessage && backup.managedRequestId
          ? {
              providerMode: 'managed' as const,
              managedRequestId: backup.managedRequestId,
              ...(backup.lastSseSequence != null ? { lastSseSequence: backup.lastSseSequence } : {}),
            }
          : {};
        if (m.state === 'generating') {
          return { ...m, text, state: 'interrupted' as const, ...managedFields };
        }
        if (text !== m.text || Object.keys(managedFields).length > 0) {
          return { ...m, text, ...managedFields };
        }
        return m;
      });
      const sanitizedConv = { ...conv, messages: updatedMessages };
      conversationsToWriteBack.push(sanitizedConv);
      return sanitizedConv;
    });
    // Write the sanitized conversation back to IDB, because lazy load reads IDB directly rather
    // than the store summary and would otherwise show generating again.
    // Awaiting the write keeps a user who lazy-loads immediately from reading stale data; 100-500ms of startup delay is acceptable.
    if (conversationsToWriteBack.length > 0) {
      await putConversationsBatch(conversationsToWriteBack, expectedUID);
      assertExpectedHydrationUID(expectedUID);
    }
    // Clear the whole map once used, so the next hydrate cannot pick it up by mistake.
    if (hasAnyBackup) clearStreamPartialBackup();
    const conversations = dedupeConversationsByID(sanitizedConversations).map(toConversationSummary);

    const preferences = getPreference<AppPreference>(
      'preferences',
      {
        theme: 'dark',
        themeSetByUser: false,
        language: 'system',
        sendShortcut: 'cmdEnter',
      },
      expectedUID,
    );
    const storedOnboarding = getPreference<boolean>('hasCompletedOnboarding', false, expectedUID);
    const hasRecoveredSetup = providers.length > 0 || conversations.length > 0;
    const hasCompletedOnboarding = storedOnboarding || hasRecoveredSetup;
    const pinnedConversationIds = getPreference<string[]>('pinnedConversationIds', [], expectedUID);
    const pinnedConversationIdsUpdatedAt = getPreference<string | undefined>(
      'pinnedConversationIdsUpdatedAt',
      undefined,
      expectedUID,
    );
    const conversationOrder = getPreference<string[]>('conversationOrder', [], expectedUID);

    // Canonical dedup on load. The older catalogModels of an official provider are kept until the
    // metadata reconcile, to recognize dirty records where enabled meant the whole old catalog, and cleared once the migration finishes.
    const dedupedProviders = providers.map((p) => {
      const recovered = recoverPersistedProviderStatus(p);
      return recovered.catalogModels.length > 0
        ? { ...recovered, catalogModels: deduplicateByCanonical(recovered.catalogModels) }
        : recovered;
    });
    const hydratedProviders = dedupeProvidersByID(dedupedProviders);
    const identityPartition = expectedUID ?? getActiveUIDSync();
    beginCapabilityEvidenceIdentitiesForLoadedProviders(
      identityPartition,
      hydratedProviders.map((provider) => provider.id),
    );

    store.setState({
      providers: hydratedProviders,
      conversations,
      folders,
      notes,
      trashedNotes,
      noteFolders,
      preferences,
      lastUsedModelRef: lastUsedModelRef ?? null,
      hasCompletedOnboarding,
      pinnedConversationIds,
      pinnedConversationIdsUpdatedAt,
      conversationOrder,
    });

    if (!storedOnboarding && hasRecoveredSetup) {
      setPreference('hasCompletedOnboarding', true, expectedUID);
    }

    // Backfill colors onto folders created before colors existed.
    assignFolderColors(store);
  } catch (error) {
    // When replaceAll is given an expectedUID it must fail loud, so the caller can abort hydration and cloud convergence for the stale partition.
    if (expectedUID !== undefined) throw error;
    //   silently fail app  
    Sentry.captureException(error, { tags: { module: 'store.hydrate' } });
  }
}

function assertExpectedHydrationUID(expectedUID?: string): void {
  if (expectedUID !== undefined && getActiveUIDSync() !== expectedUID) {
    throw new Error(`Store hydration partition changed from ${expectedUID}`);
  }
}

export async function refreshProviderMetadata(
  store: StoreApi<AppStore>,
  signal?: { cancelled: boolean },
): Promise<void> {
  const providers = store.getState().providers;
  if (providers.length === 0) {
    return;
  }

  try {
    await initMetadata();
  } catch {
    return;
  }

  // If the partition changed or unloaded during the await, drop this enrich write, so the old partition's providers are not written into the new one.
  if (signal?.cancelled) return;

  let changed = false;
  const enrichedProviders = providers.map((provider) => {
    const nextProvider = enrichProvider(provider);
    if (!changed && !providersEqual(provider, nextProvider)) {
      changed = true;
    }
    return nextProvider;
  });

  if (changed) {
    store.setState({
      providers: dedupeProvidersByID(enrichedProviders),
    });
  }
}

/* ── Subscribe: persist changes on state updates ─────── */

/**
 * Composes the per-domain subscribers defined in persistence-subscribers.ts. Each holds
 * its own prev reference, gates on hydrationPhase itself and cleans up its own timers;
 * this function only assembles them and unsubscribes them together.
 */
export function subscribeToChanges(store: StoreApi<AppStore>): () => void {
  const unsubscribers = [
    subscribeProviders(store),
    subscribeConversations(store),
    subscribePreferences(store),
    subscribeOnboarding(store),
    subscribePinned(store),
    subscribeConversationOrder(store),
    subscribeLastUsedModelRef(store),
    subscribeFolders(store),
    subscribeNotes(store),
    subscribeNoteFolders(store),
  ];
  return () => {
    for (const unsubscribe of unsubscribers) unsubscribe();
  };
}

function enrichProvider(provider: Provider): Provider {
  const enrichList = (models: Provider['models']) =>
    deduplicateByCanonical(models.map((model) => enrichStoredModel(model, provider.kind)));

  return {
    ...provider,
    models: enrichList(provider.models),
    // catalogModels for official providers are resolved dynamically from metadata, so only relay entries are enriched.
    catalogModels: provider.kind === 'relay'
      ? enrichList(provider.catalogModels)
      : provider.catalogModels,
  };
}

function providersEqual(lhs: Provider, rhs: Provider): boolean {
  //   JSON.stringify  
  if (lhs === rhs) return true;
  if (lhs.id !== rhs.id || lhs.kind !== rhs.kind || lhs.updatedAt !== rhs.updatedAt) return false;
  if (lhs.models.length !== rhs.models.length || lhs.catalogModels.length !== rhs.catalogModels.length) return false;
  // Identical model references mean the content did not change.
  if (lhs.models !== rhs.models || lhs.catalogModels !== rhs.catalogModels) return false;
  return true;
}
