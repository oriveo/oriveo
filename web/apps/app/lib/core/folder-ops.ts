/**
 * Folder operations, combining the store update and the adapter write in one transaction.
 *
 * Folder creation is unlimited, so these ops carry no quota check; backup import
 * goes through the same functions.
 */
import type { StoreApi } from 'zustand';
import type { AppStore } from './store/app-store';
import type { Conversation, Folder } from '@oriveo/shared';
import { FOLDER_COLOR_ORDER, getNextFolderColor } from '@oriveo/shared';
import { getSyncAdapter } from './sync-port';
import { createCanonicalUUID } from '../utils/id-utils';
import { trackEvent } from './telemetry';
import { getEffectiveStatusKind, isEffectiveWarning } from './providers/provider-status';

export function createFolder(store: StoreApi<AppStore>, name: string): Folder | null {
  const trimmed = name.trim().slice(0, 30);
  if (!trimmed) return null;

  const { folders } = store.getState();

  const sortOrder = folders.length === 0
    ? 1000
    : Math.max(...folders.map((f) => f.sortOrder)) + 1000;

  const colorTag = getNextFolderColor(folders);

  const folder: Folder = {
    id: createCanonicalUUID(),
    name: trimmed,
    sortOrder,
    colorTag,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
  };

  store.getState().addFolder(folder);
  getSyncAdapter()?.didCreateFolder(folder);
  trackEvent('folder_created', {
    color: colorTag,
    folder_count: folders.length + 1,
  });
  return folder;
}

export function renameFolder(store: StoreApi<AppStore>, id: string, name: string) {
  const trimmed = name.trim().slice(0, 30);
  if (!trimmed) return;
  store.getState().updateFolder(id, { name: trimmed, updatedAt: new Date().toISOString() });
  getSyncAdapter()?.didUpdateFolder(id, { name: trimmed });
}

export function deleteFolder(store: StoreApi<AppStore>, id: string) {
  const affectedConvIds = store.getState().conversations
    .filter((c) => c.folderID === id)
    .map((c) => c.id);

  store.getState().removeFolder(id);
  getSyncAdapter()?.didDeleteFolder(id, affectedConvIds);
}

export function reorderFolders(store: StoreApi<AppStore>, reordered: Folder[]) {
  //   ≤ 1 
  const needsRebalance = reordered.some((f, i) =>
    i > 0 && f.sortOrder - reordered[i - 1].sortOrder <= 1
  );

  if (needsRebalance) {
    //  1000, 2000, 3000...
    const now = new Date().toISOString();
    reordered = reordered.map((f, i) => ({
      ...f,
      sortOrder: (i + 1) * 1000,
      updatedAt: now,
    }));
  }

  store.getState().reorderFolders(reordered);
  getSyncAdapter()?.didReorderFolders(reordered);
}

export function moveConversationToFolder(
  store: StoreApi<AppStore>,
  convID: string,
  folderID: string | null,
) {
  const metadataUpdatedAt = new Date().toISOString();
  store.getState().updateConversation(convID, {
    folderID: folderID ?? undefined,
    firestoreMetadataUpdatedAt: metadataUpdatedAt,
  });
  getSyncAdapter()?.didMoveConversationToFolder(convID, folderID);
}

export function batchMoveToFolder(
  store: StoreApi<AppStore>,
  convIDs: string[],
  folderID: string | null,
) {
  if (convIDs.length === 0) return;

  const state = store.getState();
  const metadataUpdatedAt = new Date().toISOString();

  //   store 
  const conversations = state.conversations.map((c) =>
    convIDs.includes(c.id)
      ? { ...c, folderID: folderID ?? undefined, firestoreMetadataUpdatedAt: metadataUpdatedAt }
      : c
  );

  store.setState({ conversations });

  // One batched notification for the whole move.
  getSyncAdapter()?.didBatchMoveToFolder(convIDs, folderID);
}

/** Handles drag-and-drop reordering of folders. */
export function handleFolderReorder(
  store: StoreApi<AppStore>,
  sourceFolderId: string,
  targetFolderId: string,
) {
  const folders = store.getState().folders;
  const sourceIdx = folders.findIndex((f) => f.id === sourceFolderId);
  const targetIdx = folders.findIndex((f) => f.id === targetFolderId);

  if (sourceIdx === -1 || targetIdx === -1 || sourceIdx === targetIdx) return;

  // Remove the source and insert it before the target.
  const reordered = [...folders];
  const [source] = reordered.splice(sourceIdx, 1);
  const newTargetIdx = sourceIdx < targetIdx ? targetIdx - 1 : targetIdx;
  reordered.splice(newTargetIdx, 0, source);

  //   sortOrder 
  reordered.forEach((f, i) => {
    const prev = i > 0 ? reordered[i - 1].sortOrder : 0;
    const next = i < reordered.length - 1 ? reordered[i + 1].sortOrder : prev + 2000;
    f.sortOrder = Math.floor((prev + next) / 2);
  });

  reorderFolders(store, reordered);
}

/**
 * Creates a draft conversation inside the given folder.
 *
 * Conversation.providerKind is a required contract, so the draft binds the kind, id and
 * model of the default provider at creation time:
 *  - lastUsedModelRef when available
 *  - otherwise the default model of the first active provider
 *  - callers must ensure the store holds at least one usable provider
 *
 * Returns null when no active provider is found, in which case the UI should disable the
 * new conversation button.
 */
export function createConversationInFolder(
  store: StoreApi<AppStore>,
  folderID: string,
): string | null {
  const defaults = resolveDefaultProviderModel(store);
  if (!defaults) return null;

  const conv: Conversation = {
    // createCanonicalUUID is required (uppercase canonical): the value ends up in route
    // parameters and is matched exactly against streaming state, and the lowercase form a
    // bare randomUUID produces makes the streaming indicator selector miss.
    id: createCanonicalUUID(),
    title: '',
    hasCustomTitle: false,
    providerID: defaults.provider.id,
    providerKind: defaults.provider.kind,
    relayKind: defaults.provider.kind === 'relay' ? defaults.provider.relayKind : undefined,
    modelID: defaults.modelId,
    previewText: '',
    estimatedCost: 0,
    isDraft: true,
    messages: [],
    draftText: '',
    updatedAt: new Date().toISOString(),
    createdAt: new Date().toISOString(),
    folderID,
  };

  store.getState().addConversation(conv);
  store.getState().setActiveConversationId(conv.id);
  return conv.id;
}

function resolveDefaultProviderModel(
  store: StoreApi<AppStore>,
): { provider: AppStore['providers'][number]; modelId: string } | null {
  const { providers, lastUsedModelRef } = store.getState();
  // A provider with no key on this device cannot actually be used and must be excluded from the active set; the effective status matches needsKey.
  const active = providers.filter((p) => !isEffectiveWarning(getEffectiveStatusKind(p)) && p.models.length > 0);
  if (active.length === 0) return null;

  if (lastUsedModelRef) {
    const provider = active.find((p) => p.id === lastUsedModelRef.providerID);
    const model = provider?.models.find((m) => m.id === lastUsedModelRef.modelID);
    if (provider && model) return { provider, modelId: model.id };
  }

  for (const provider of active) {
    const model = provider.models.find((m) => m.isDefault) ?? provider.models[0];
    if (model) return { provider, modelId: model.id };
  }
  return null;
}

/** Updates a folder's color. */
export function updateFolderColor(store: StoreApi<AppStore>, id: string, colorTag: string) {
  store.getState().updateFolder(id, { colorTag, updatedAt: new Date().toISOString() });
  getSyncAdapter()?.didUpdateFolder(id, { colorTag });
}

/** Migration for existing data: assigns a color to every folder whose colorTag is empty. */
export function assignFolderColors(store: StoreApi<AppStore>) {
  const folders = [...store.getState().folders].sort((a, b) => a.sortOrder - b.sortOrder);
  if (folders.every((f) => f.colorTag)) return;

  let previousIndex = -1;
  for (const folder of folders) {
    if (!folder.colorTag) {
      const nextIndex = (previousIndex + 1) % FOLDER_COLOR_ORDER.length;
      const colorTag = FOLDER_COLOR_ORDER[nextIndex];
      store.getState().updateFolder(folder.id, { colorTag, updatedAt: new Date().toISOString() });
      getSyncAdapter()?.didUpdateFolder(folder.id, { colorTag });
      previousIndex = nextIndex;
    } else {
      const idx = FOLDER_COLOR_ORDER.indexOf(folder.colorTag);
      if (idx >= 0) previousIndex = idx;
    }
  }
}
