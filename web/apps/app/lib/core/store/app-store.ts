import { createStore } from 'zustand/vanilla';
import type { StorageHealth } from '../storage-health';
import type {
  Provider,
  Conversation,
  Folder,
  Note,
  NoteFolder,
  UserProfile,
  AppPreference,
  LastUsedModelRef,
  AppTab,
  Skill,
  SkillUsage,
  SkillCategory,
} from '@oriveo/shared';
import { createStreamingSlice } from './slices/streaming-slice';
import { createProviderSlice } from './slices/provider-slice';
import { createConversationSlice } from './slices/conversation-slice';
import { createSkillsSlice } from './slices/skills-slice';
import { createPinSlice } from './slices/pin-slice';
import { createFolderSlice } from './slices/folder-slice';
import { createNoteSlice } from './slices/note-slice';
import { createNoteFolderSlice } from './slices/note-folder-slice';
import { createMemorySlice } from './slices/memory-slice';
import { createSyncSlice } from './slices/sync-slice';
import { createAppSlice } from './slices/app-slice';
import { createLibrarySlice } from './slices/library-slice';
import type {
  LibraryConfirmationRequest,
  LibraryConnection,
  LibraryConnectionQuota,
  LibraryQuota,
  LibraryResearchStep,
} from '../library/types';

/* ── State shape ─────────────────────────────────────── */

export interface AppState {
  /* Data */
  providers: Provider[];
  conversations: Conversation[];
  account: UserProfile | null;
  preferences: AppPreference;
  lastUsedModelRef: LastUsedModelRef | null;

  /* UI */
  selectedTab: AppTab;
  activeConversationId: string | null;
  sidebarOpen: boolean;
  hasCompletedOnboarding: boolean;
  /**
   * Streaming state, keyed per conversation.
   *
   * One partial per conversation: the top-level ChatView selector reads it by
   * effectiveId, while the list layer subscribes to the streamingConversationIds array,
   * whose reference only changes on add and remove.
   * Invariant: the keys of streamingConversationIds, streamingTexts,
   * streamingMessageIds and streamingReasoningTexts must stay in sync, and the only
   * mutation entry points are beginStreamingForConversation and
   * clearStreamingForConversation.
   */
  streamingTexts: Record<string, string>;
  /** Reasoning partial, with the same lifecycle as streamingTexts. An empty string means reasoning has not started. */
  streamingReasoningTexts: Record<string, string>;
  /**
   * Explicit "reasoning has started" signal, with the same lifecycle as
   * streamingReasoningTexts.
   *
   * `streamingReasoningTexts[convId] !== ''` cannot stand in for it: upstreams such as
   * DeepSeek send `reasoning_content: ""` heartbeats during a long think and only emit
   * the real content once the whole reasoning block finishes (a first non-empty
   * reasoning chunk at 279s has been observed). The text stays an empty string until
   * then, so a "text is non-empty" test leaves the UI with no feedback for minutes,
   * and the empty string is worthless in the text pipeline anyway (appending it changes
   * nothing and it gets trimmed downstream). The signal is therefore this boolean, set
   * by stream-runner on the first reasoning event regardless of its content.
   */
  streamingReasoningActive: Record<string, boolean>;
  streamingMessageIds: Record<string, string>;
  streamingConversationIds: string[];

  /* Search */
  searchQuery: string;
  searchMatchIndex: number;

  /* Image generation */
  imageGenMode: boolean;

  /* Pin & order */
  pinnedConversationIds: string[];
  /** LWW timestamp for the pin list (ISO 8601). Local pin changes update it through
   *  togglePinConversation/removeConversations; remote LWW sync sets it through
   *  applyRemotePinnedConversationIds. Used only for sync decisions, never displayed. */
  pinnedConversationIdsUpdatedAt: string | undefined;
  conversationOrder: string[];

  /* Folders */
  folders: Folder[];
  expandedFolderIds: string[];

  /* Notes */
  /** Active notes (deletedAt == null). */
  notes: Note[];
  /** Trashed notes (deletedAt != null); this is the data source, so the UI does not re-query IDB. */
  trashedNotes: Note[];
  /** Note folders, active only; soft-delete tombstones stay remote and never enter the store. */
  noteFolders: NoteFolder[];
  /** Ids of the note folders currently expanded in the sidebar tree. */
  expandedNoteFolderIds: string[];
  /** Ids of locally soft-deleted notes, so the cloud listener cannot write the old documents back into notes. */
  locallyDeletedNoteIds: string[];

  /** Synchronisation */
  syncBanner: string | null;
  remotelyDeletedConvID: string | null;
  locallyDeletedConversationIds: string[];
  syncState: 'idle' | 'syncing' | 'error' | 'disabled';

  /**
   * Hydration phase:
   *   - 'booting': starting up (IDB and metadata not ready), so the UI shows a skeleton
   *   - 'metadata-pending': IDB is hydrated and metadata is still refreshing
   *   - 'ready': everything is available and the UI can render normally
   */
  hydrationPhase: 'booting' | 'metadata-pending' | 'ready';

  /**
   * Browser persistence health, probed once at startup.
   * null means the probe has not finished; `persistent: false` means nothing can be
   * stored on this machine, which the UI must state plainly, or users will assume
   * their data was saved and find it all gone on the next visit.
   */
  storageHealth: StorageHealth | null;

  /* Memory (local only, never synced) */
  memoryUsageCount: number;

  /* Skills */
  catalogSkills: Skill[];
  userSkills: Skill[];
  skillCategories: SkillCategory[];
  skillUsage: SkillUsage | null;
  catalogVersion: number | null;

  /* Library (per-account; never written to local persistence) */
  libraryConnections: LibraryConnection[];
  libraryQuota: LibraryQuota | null;
  libraryConnectionQuota: LibraryConnectionQuota | null;
  libraryLoadState: 'idle' | 'loading' | 'ready' | 'error';
  libraryErrorCode: string | null;
  libraryResearchEnabled: boolean;
  libraryResearchSteps: Record<string, LibraryResearchStep[]>;
  libraryConfirmation: LibraryConfirmationRequest | null;
}

/* ── Actions ─────────────────────────────────────────── */

export interface AppActions {
  /* Providers */
  setProviders: (providers: Provider[]) => void;
  addProvider: (provider: Provider) => void;
  updateProvider: (id: string, patch: Partial<Provider>) => void;
  removeProvider: (id: string) => void;

  /* Conversations */
  setConversations: (conversations: Conversation[]) => void;
  addConversation: (conversation: Conversation) => void;
  updateConversation: (id: string, patch: Partial<Conversation>) => void;
  removeConversation: (id: string) => void;

  /* Navigation / UI */
  setActiveConversationId: (id: string | null) => void;
  setSelectedTab: (tab: AppTab) => void;
  setSidebarOpen: (open: boolean) => void;
  setHasCompletedOnboarding: (value: boolean) => void;
  /* Account */
  setAccount: (account: UserProfile | null) => void;

  /* Preferences */
  setPreferences: (prefs: Partial<AppPreference>) => void;

  /* Streaming (multi-conversation) */
  setStreamingText: (convId: string, text: string) => void;
  appendStreamingText: (convId: string, chunk: string) => void;
  /** Set the reasoning partial, used to reset or initialize it on a continuation. */
  setStreamingReasoningText: (convId: string, text: string) => void;
  /** Append a reasoning partial chunk on the streaming reasoning path. */
  appendStreamingReasoningText: (convId: string, chunk: string) => void;
  /** Mark reasoning as started for the conversation; called on the first reasoning event regardless of whether the text is empty. Idempotent. */
  markStreamingReasoningStarted: (convId: string) => void;
  /** Register a stream: writes streamingMessageIds[convId] + streamingTexts[convId]='' + streamingReasoningTexts[convId]='' and pushes convId into streamingConversationIds. */
  beginStreamingForConversation: (convId: string, msgId: string) => void;
  /** Clear a stream: removes convId from every dictionary and array together. */
  clearStreamingForConversation: (convId: string) => void;

  /* Session */
  setLastUsedModelRef: (ref: LastUsedModelRef | null) => void;

  /* Search */
  setSearchQuery: (query: string) => void;
  setSearchMatchIndex: (index: number) => void;

  /* Image generation */
  setImageGenMode: (mode: boolean) => void;

  /* Pin & order */
  togglePinConversation: (id: string, limit?: number) => boolean;
  setConversationOrder: (order: string[]) => void;
  removeConversations: (ids: string[]) => void;
  /** Remote LWW sync only: uses remoteUpdatedAt as the new timestamp instead of togglePin's "now", which would otherwise loop. */
  applyRemotePinnedConversationIds: (ids: string[], remoteUpdatedAt: string) => void;

  /* Folders */
  setFolders: (folders: Folder[]) => void;
  addFolder: (folder: Folder) => void;
  updateFolder: (id: string, patch: Partial<Folder>) => void;
  removeFolder: (id: string) => void;
  reorderFolders: (folders: Folder[]) => void;
  toggleFolderExpand: (id: string) => void;

  /* Notes */
  setNotes: (notes: Note[]) => void;
  setTrashedNotes: (notes: Note[]) => void;
  addNote: (note: Note) => void;
  updateNote: (id: string, patch: Partial<Note>) => void;
  /** Hard-remove one note (a blank draft, or one removed remotely); does not go to the trash. */
  discardNote: (id: string) => void;
  /** Soft-delete into the trash; deletedAt is the ISO string the caller generates, and doubles as updatedAt. */
  removeNote: (id: string, deletedAt: string) => void;
  /** Restore from the trash; updatedAt is the ISO string the caller generates, bumping LWW past the deletion. */
  restoreNote: (id: string, updatedAt: string) => void;
  /** Empty the trash at the store layer; the real IDB and remote deletes are note-ops' job. */
  emptyTrash: () => void;
  clearLocallyDeletedNote: (id: string) => void;

  /* NoteFolders */
  setNoteFolders: (folders: NoteFolder[]) => void;
  addNoteFolder: (folder: NoteFolder) => void;
  updateNoteFolder: (id: string, patch: Partial<NoteFolder>) => void;
  removeNoteFolder: (id: string) => void;
  reorderNoteFolders: (folders: NoteFolder[]) => void;
  toggleNoteFolderExpand: (id: string) => void;

  /* Sync */
  setSyncBanner: (banner: string | null) => void;
  clearRemotelyDeletedConvID: () => void;
  clearLocallyDeletedConversation: (id: string) => void;

  /* Memory */
  setConversationUseMemory: (conversationId: string, useMemory: boolean) => void;
  incrementMemoryUsageCount: () => void;

  /* Skills */
  setCatalogSkills: (skills: Skill[], categories: SkillCategory[], version: number) => void;
  setUserSkills: (skills: Skill[], usage: SkillUsage) => void;
  updateSkillInStore: (id: string, patch: Partial<Skill>) => void;
  addUserSkill: (skill: Skill) => void;
  removeUserSkill: (id: string) => void;

  /* Library */
  setLibraryConnections: (connections: LibraryConnection[]) => void;
  setLibraryQuota: (quota: LibraryQuota | null) => void;
  setLibraryConnectionQuota: (quota: LibraryConnectionQuota | null) => void;
  setLibraryLoadState: (state: AppState['libraryLoadState'], errorCode?: string | null) => void;
  setLibraryResearchEnabled: (enabled: boolean) => void;
  setLibraryResearchSteps: (conversationId: string, steps: LibraryResearchStep[]) => void;
  setLibraryConfirmation: (confirmation: LibraryConfirmationRequest | null) => void;
  resetLibraryState: () => void;
}

/* ── Store type ──────────────────────────────────────── */

export type AppStore = AppState & AppActions;

/* ── Default state ───────────────────────────────────── */

export const defaultState: AppState = {
  providers: [],
  conversations: [],
  account: null,
  preferences: { theme: 'dark', themeSetByUser: false, language: 'system', sendShortcut: 'enter' },
  lastUsedModelRef: null,
  selectedTab: 'home',
  activeConversationId: null,
  sidebarOpen: true,
  hasCompletedOnboarding: false,
  streamingTexts: {},
  streamingReasoningTexts: {},
  streamingReasoningActive: {},
  streamingMessageIds: {},
  streamingConversationIds: [],
  searchQuery: '',
  searchMatchIndex: 0,
  imageGenMode: false,
  pinnedConversationIds: [],
  pinnedConversationIdsUpdatedAt: undefined,
  conversationOrder: [],
  folders: [],
  expandedFolderIds: [],
  notes: [],
  trashedNotes: [],
  noteFolders: [],
  expandedNoteFolderIds: [],
  locallyDeletedNoteIds: [],
  syncBanner: null,
  remotelyDeletedConvID: null,
  locallyDeletedConversationIds: [],
  syncState: 'disabled',
  hydrationPhase: 'booting',
  storageHealth: null,
  memoryUsageCount: 0,
  catalogSkills: [],
  userSkills: [],
  skillCategories: [],
  skillUsage: null,
  catalogVersion: null,
  libraryConnections: [],
  libraryQuota: null,
  libraryConnectionQuota: null,
  libraryLoadState: 'idle',
  libraryErrorCode: null,
  libraryResearchEnabled: false,
  libraryResearchSteps: {},
  libraryConfirmation: null,
};

/* ── Create store ────────────────────────────────────── */

export function createAppStore(initial: Partial<AppState> = {}) {
  return createStore<AppStore>()((set, get) => ({
    ...defaultState,
    ...initial,
    ...createStreamingSlice(set),
    ...createProviderSlice(set),
    ...createConversationSlice(set, get),
    ...createSkillsSlice(set),
    ...createPinSlice(set),
    ...createFolderSlice(set),
    ...createNoteSlice(set),
    ...createNoteFolderSlice(set),
    ...createMemorySlice(set),
    ...createSyncSlice(set),
    ...createAppSlice(set),
    ...createLibrarySlice(set),
  }));
}
