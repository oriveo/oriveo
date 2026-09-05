export {
  getAllConversations,
  putConversation,
  deleteConversation,
  getAllProviders,
  putProvider,
  putProviderIfCurrent,
  deleteProvider,
  deleteProviderFromPartition,
  deleteProviderAndEnqueuePendingDeletion,
  putProviderAndCancelPendingDeletion,
  putProviderAndCancelPendingDeletionIfCurrent,
  getPendingProviderDeletions,
  clearPendingProviderDeletions,
  getSessionValue,
  setSessionValue,
  resetDBConnection,
  clearAllConversations,
  clearAllProviders,
  enqueuePendingConversationDeletions,
  getPendingConversationDeletions,
  clearPendingConversationDeletions,
} from './idb';
export type { PendingProviderDeletion } from './idb';

export { getPreference, setPreference, removePreference } from './preferences';
// Accepted risk: BYOK keys are currently stored in IndexedDB in plaintext on web, the same model
// used by browser BYOK clients such as the OpenAI Playground, Cursor and Cline. For the strongest
// guarantees use the iOS or Android client, where the system keychain or keystore encrypts them.

export {
  getActiveUID,
  setActiveUID,
  getDBName,
  getImageDBName,
  hasPartitionData,
  metaDBExists,
  legacyDBExists,
} from './partition';

export {
  saveImage,
  loadImageData,
  loadImageBase64,
  loadThumbnailData,
  deleteImage,
  imageExists,
  generateThumbnail,
  resetImageDBConnection,
} from './image-store';

export { migrateToPartitionedStorage } from './migration';
