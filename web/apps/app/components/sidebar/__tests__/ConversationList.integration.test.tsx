// @vitest-environment jsdom
//
// Integration tests for the key sidebar paths, rendered from the ConversationList level down.
//
// These do not overlap the hook unit tests, which call the hooks directly to check pure logic.
// This file renders the real component tree, ConversationList -> ConversationGroup ->
// ConversationItem / FolderSection -> FolderItem -> ContextMenu / MoveToFolderMenu / ConfirmDialog,
// and checks that a user gesture is really wired to the right store op or route push.
//
// Only leaves and external dependencies are mocked (store, conversation-ops, folder-ops, Toast,
// ProviderIcon, warmConversationInStore).

import { act, fireEvent, render, screen, waitFor, within, cleanup } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Conversation, Folder } from '@oriveo/shared';

const { routerPush } = vi.hoisted(() => ({ routerPush: vi.fn() }));
const {
  mockDeleteConversation,
  mockDeleteConversations,
  mockUpdateConversationTitle,
  mockCloneFromConflict,
  mockCleanupConflictCopies,
  mockGetConversationNoteReferenceCount,
} = vi.hoisted(() => ({
  mockDeleteConversation: vi.fn(),
  mockDeleteConversations: vi.fn(),
  mockUpdateConversationTitle: vi.fn(),
  mockCloneFromConflict: vi.fn(() => 'cloned-id'),
  mockCleanupConflictCopies: vi.fn(),
  mockGetConversationNoteReferenceCount: vi.fn(() => 0),
}));
const {
  mockMoveConversationToFolder,
  mockBatchMoveToFolder,
  mockDeleteFolder,
  mockRenameFolder,
  mockUpdateFolderColor,
  mockCreateConversationInFolder,
  mockCreateFolder,
} = vi.hoisted(() => ({
  mockMoveConversationToFolder: vi.fn(),
  mockBatchMoveToFolder: vi.fn(),
  mockDeleteFolder: vi.fn(),
  mockRenameFolder: vi.fn(),
  mockUpdateFolderColor: vi.fn(),
  mockCreateConversationInFolder: vi.fn(() => 'new-conv-in-folder'),
  mockCreateFolder: vi.fn(),
}));
const { mockSearchConversations } = vi.hoisted(() => ({
  mockSearchConversations: vi.fn(async () => [] as Conversation[]),
}));

// next/navigation: overrides the global mock from setup.ts with a stable push so route changes can be asserted.
vi.mock('next/navigation', () => ({
  useRouter: () => ({ push: routerPush, replace: vi.fn(), back: vi.fn(), prefetch: vi.fn() }),
  usePathname: () => '/chat',
  useSearchParams: () => new URLSearchParams(),
}));

// Shared store state: every test resets it in beforeEach and overrides the fields it needs.
type MockState = Record<string, unknown>;
let mockState: MockState;
const vanillaStore = { getState: () => mockState };

vi.mock('../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: MockState) => unknown) => selector(mockState),
  getVanillaStore: () => vanillaStore,
}));

vi.mock('../../../lib/core/conversation-ops', () => ({
  deleteConversation: (...a: unknown[]) => mockDeleteConversation(...a),
  deleteConversations: (...a: unknown[]) => mockDeleteConversations(...a),
  updateConversationTitle: (...a: unknown[]) => mockUpdateConversationTitle(...a),
  cloneConversationFromConflictCopy: (...a: unknown[]) => mockCloneFromConflict(...a),
  cleanupConflictCopies: (...a: unknown[]) => mockCleanupConflictCopies(...a),
  getConversationNoteReferenceCount: (...a: unknown[]) => mockGetConversationNoteReferenceCount(...a),
}));

vi.mock('../../../lib/core/folder-ops', () => ({
  moveConversationToFolder: (...a: unknown[]) => mockMoveConversationToFolder(...a),
  batchMoveToFolder: (...a: unknown[]) => mockBatchMoveToFolder(...a),
  deleteFolder: (...a: unknown[]) => mockDeleteFolder(...a),
  renameFolder: (...a: unknown[]) => mockRenameFolder(...a),
  updateFolderColor: (...a: unknown[]) => mockUpdateFolderColor(...a),
  createConversationInFolder: (...a: unknown[]) => mockCreateConversationInFolder(...a),
  createFolder: (...a: unknown[]) => mockCreateFolder(...a),
}));

vi.mock('../../../lib/infra/storage/idb', () => ({
  searchConversations: (...a: unknown[]) => mockSearchConversations(...a),
}));

vi.mock('../../../lib/core/chat/conversation-bootstrap', () => ({
  warmConversationInStore: vi.fn(),
}));

vi.mock('../../ProviderIcon', () => ({
  ProviderIcon: () => <span data-testid="provider-icon" />,
}));

vi.mock('../../Toast', () => ({ showToast: vi.fn() }));

import { ConversationList } from '../ConversationList';

function makeConv(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: 'c1',
    title: 'Conversation',
    hasCustomTitle: false,
    providerID: 'provider-1',
    providerKind: 'openAI',
    modelID: 'model-1',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages: [],
    draftText: '',
    createdAt: '2026-04-10T00:00:00.000Z',
    updatedAt: '2026-04-10T00:00:00.000Z',
    ...overrides,
  };
}

function makeFolder(overrides: Partial<Folder> = {}): Folder {
  return {
    id: 'f1',
    name: 'Work',
    colorTag: 'blue',
    sortOrder: 0,
    createdAt: '2026-04-01T00:00:00.000Z',
    updatedAt: '2026-04-01T00:00:00.000Z',
    ...overrides,
  } as Folder;
}

function setState(partial: MockState) {
  mockState = {
    ...mockState,
    ...partial,
  };
}

function renderList() {
  return render(<ConversationList />);
}

/** DataTransfer stub with working setData/getData/types; the jsdom default is incomplete. */
function makeDataTransfer() {
  const data = new Map<string, string>();
  const dt = {
    effectAllowed: '',
    dropEffect: '',
    types: [] as string[],
    setData(type: string, val: string) {
      data.set(type, val);
      if (!dt.types.includes(type)) dt.types.push(type);
    },
    getData(type: string) {
      return data.get(type) ?? '';
    },
  };
  return dt;
}

/** Returns the draggable root of a conversation row (role=button + draggable). */
function convRow(title: string): HTMLElement {
  const el = screen.getByText(title).closest('[role="button"]');
  if (!el) throw new Error(`conversation row not found: ${title}`);
  return el as HTMLElement;
}

beforeEach(() => {
  vi.clearAllMocks();
  mockGetConversationNoteReferenceCount.mockReturnValue(0);
  mockSearchConversations.mockResolvedValue([]);
  // pointer:fine means desktop, which enables drag and drop plus the context menu.
  window.matchMedia = vi.fn().mockImplementation((query: string) => ({
    matches: true,
    media: query,
    onchange: null,
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    addListener: vi.fn(),
    removeListener: vi.fn(),
    dispatchEvent: vi.fn(),
  })) as unknown as typeof window.matchMedia;
  // The Dialog in @oriveo/ui focuses through rAF; run it synchronously to avoid hanging.
  vi.stubGlobal('requestAnimationFrame', (cb: FrameRequestCallback) => {
    cb(0);
    return 1;
  });
  mockState = {
    conversations: [],
    activeConversationId: null,
    pinnedConversationIds: [],
    pinnedConversationIdsUpdatedAt: undefined,
    conversationOrder: [],
    folders: [],
    expandedFolderIds: [],
    streamingConversationIds: [],
    providers: [],
    catalogSkills: [],
    userSkills: [],
    syncState: 'disabled',
    account: null,
    setConversationOrder: vi.fn(),
    togglePinConversation: vi.fn(() => true),
    toggleFolderExpand: vi.fn(),
  };
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

describe('ConversationList key integration paths', () => {
  // 1) Drag a pinned conversation to reorder -> setConversationOrder (wiring: usePinnedReorder -> pinned ConversationGroup)
  it('dragging a pinned conversation to another position writes back the reordered conversationOrder', () => {
    const setConversationOrder = vi.fn();
    setState({
      conversations: [makeConv({ id: 'p1', title: 'Pinned One' }), makeConv({ id: 'p2', title: 'Pinned Two' })],
      pinnedConversationIds: ['p1', 'p2'],
      setConversationOrder,
    });
    renderList();

    const dt = makeDataTransfer();
    fireEvent.dragStart(convRow('Pinned One'), { dataTransfer: dt });
    fireEvent.dragOver(convRow('Pinned Two'), { dataTransfer: dt });
    fireEvent.drop(convRow('Pinned Two'), { dataTransfer: dt });

    expect(setConversationOrder).toHaveBeenCalledWith(['p2', 'p1']);
  });

  // 2) Drag a conversation onto a folder header -> moveConversationToFolder (wiring: useFolderDragTarget)
  it('dragging a pinned conversation onto a folder header calls moveConversationToFolder', () => {
    setState({
      conversations: [makeConv({ id: 'p1', title: 'Draggable Conv' })],
      pinnedConversationIds: ['p1'],
      folders: [makeFolder({ id: 'f1', name: 'Work' })],
    });
    renderList();

    const dt = makeDataTransfer();
    fireEvent.dragStart(convRow('Draggable Conv'), { dataTransfer: dt });
    const folderHeader = screen.getByRole('button', { name: /Work/ });
    fireEvent.dragOver(folderHeader, { dataTransfer: dt });
    fireEvent.drop(folderHeader, { dataTransfer: dt });

    expect(mockMoveConversationToFolder).toHaveBeenCalledWith(vanillaStore, 'p1', 'f1');
  });

  // 3) Context menu -> rename -> type and press Enter -> updateConversationTitle (wiring: useInlineRename plus the context menu)
  it('renaming from the context menu and pressing Enter calls updateConversationTitle', () => {
    setState({ conversations: [makeConv({ id: 'c1', title: 'Rename Me' })] });
    renderList();

    fireEvent.contextMenu(convRow('Rename Me'));
    fireEvent.click(screen.getByRole('menuitem', { name: 'rename' }));

    const input = screen.getByDisplayValue('Rename Me');
    fireEvent.change(input, { target: { value: 'New Title' } });
    fireEvent.keyDown(input, { key: 'Enter' });

    expect(mockUpdateConversationTitle).toHaveBeenCalledWith(vanillaStore, 'c1', 'New Title');
  });

  // 4) Edit mode -> select the active conversation -> confirm the batch delete -> deleteConversations plus a push to /chat
  it('batch delete goes through ConfirmDialog and pushes /chat when the active conversation is removed', () => {
    setState({
      conversations: [makeConv({ id: 'c1', title: 'Active Conv' })],
      activeConversationId: 'c1',
    });
    renderList();

    fireEvent.click(screen.getByRole('button', { name: 'editMode' }));
    fireEvent.click(convRow('Active Conv'));
    // The toolbar now shows batchDelete (1)
    fireEvent.click(screen.getByRole('button', { name: 'batchDelete (1)' }));
    // Nothing is deleted until the confirmation dialog is answered
    expect(mockDeleteConversations).not.toHaveBeenCalled();
    // ConfirmDialog confirm button, matched by the exact name 'batchDelete' to tell it apart from the toolbar 'batchDelete (1)'
    fireEvent.click(screen.getByRole('button', { name: 'batchDelete' }));

    expect(mockDeleteConversations).toHaveBeenCalledWith(vanillaStore, ['c1']);
    expect(routerPush).toHaveBeenCalledWith('/chat');
  });

  // 5) Select all in edit mode -> every row selected (wiring: useBatchEditMode.selectAll -> SidebarToolbar)
  it('clicking select all in edit mode selects every conversation and switches the toolbar to deselect all', () => {
    setState({
      conversations: [
        makeConv({ id: 'a', title: 'Alpha' }),
        makeConv({ id: 'b', title: 'Bravo' }),
        makeConv({ id: 'c', title: 'Charlie' }),
      ],
    });
    renderList();

    fireEvent.click(screen.getByRole('button', { name: 'editMode' }));
    fireEvent.click(screen.getByRole('button', { name: 'selectAll' }));

    const checkboxes = screen.getAllByRole('checkbox');
    expect(checkboxes).toHaveLength(3);
    expect(checkboxes.every((cb) => cb.getAttribute('aria-checked') === 'true')).toBe(true);
    expect(screen.getByRole('button', { name: 'deselectAll' })).toBeTruthy();
  });

  // 6) Context menu -> move to folder -> pick a target -> moveConversationToFolder (wiring: MoveToFolderMenu)
  it('moving to a folder from the context menu calls moveConversationToFolder', () => {
    setState({
      conversations: [makeConv({ id: 'c1', title: 'Movable' })],
      folders: [makeFolder({ id: 'f1', name: 'Archive' })],
    });
    renderList();

    fireEvent.contextMenu(convRow('Movable'));
    fireEvent.click(screen.getByRole('menuitem', { name: 'moveToFolder' }));
    // The folder named Archive shows up twice: as the sidebar folder header, which carries
    // aria-expanded, and inside MoveToFolderMenu. Pick the menu entry, the one without aria-expanded.
    const archiveButtons = screen.getAllByRole('button', { name: 'Archive' });
    const menuEntry = archiveButtons.find((b) => !b.hasAttribute('aria-expanded'));
    expect(menuEntry).toBeTruthy();
    fireEvent.click(menuEntry!);

    expect(mockMoveConversationToFolder).toHaveBeenCalledWith(vanillaStore, 'c1', 'f1');
  });

  // 7) Folder context menu -> delete -> ConfirmDialog -> deleteFolder
  it('deleting a folder from the context menu goes through ConfirmDialog and calls deleteFolder', () => {
    setState({
      conversations: [],
      folders: [makeFolder({ id: 'f1', name: 'Trash Me' })],
    });
    renderList();

    fireEvent.contextMenu(screen.getByRole('button', { name: /Trash Me/ }));
    fireEvent.click(screen.getByRole('menuitem', { name: 'deleteFolder' }));
    expect(mockDeleteFolder).not.toHaveBeenCalled();
    // ConfirmDialog confirm, a destructive action whose button is labelled 'deleteFolder'
    const dialog = screen.getByRole('dialog');
    fireEvent.click(within(dialog).getByRole('button', { name: 'deleteFolder' }));

    expect(mockDeleteFolder).toHaveBeenCalledWith(vanillaStore, 'f1');
  });

  // 8) New chat inside a folder -> createConversationInFolder plus a push to the new conversation
  it('new chat inside a folder calls createConversationInFolder and navigates to it', () => {
    setState({
      conversations: [],
      folders: [makeFolder({ id: 'f1', name: 'Empty Folder' })],
      expandedFolderIds: ['f1'],
    });
    renderList();

    fireEvent.click(screen.getByRole('button', { name: 'newChatInFolder' }));

    expect(mockCreateConversationInFolder).toHaveBeenCalledWith(vanillaStore, 'f1');
    expect(routerPush).toHaveBeenCalledWith('/chat/new-conv-in-folder');
  });

  // 9) Conflict copies: rendered when copies exist and no search is active, hidden while searching (wiring condition: !searchQuery && copies>0)
  it('renders ConflictCopyGroup when conflict copies exist and no search is active, and hides it while searching', () => {
    setState({
      conversations: [
        makeConv({ id: 'c1', title: 'Normal' }),
        makeConv({ id: 'copy-1', title: '🔀 Conflict', isConflictCopy: true, conflictOriginId: 'c1' }),
      ],
    });
    renderList();

    expect(screen.getByRole('button', { name: /syncMerge\.conflictCopy\.section/ })).toBeTruthy();

    fireEvent.change(screen.getByPlaceholderText('searchPlaceholder'), { target: { value: 'normal' } });
    expect(screen.queryByRole('button', { name: /syncMerge\.conflictCopy\.section/ })).toBeNull();
  });

  // 10) IndexedDB search path: fewer than two characters never fires, two or more call searchConversations after a 300ms debounce
  it('search hits IndexedDB after the debounce at two or more characters, and not below that or before the debounce elapses', async () => {
    vi.useFakeTimers();
    try {
      setState({ conversations: [makeConv({ id: 'c1', title: 'Searchable' })] });
      renderList();
      const input = screen.getByPlaceholderText('searchPlaceholder');

      // A single character is stopped by the query.length < 2 guard
      fireEvent.change(input, { target: { value: 'a' } });
      await act(async () => {
        vi.advanceTimersByTime(400);
      });
      expect(mockSearchConversations).not.toHaveBeenCalled();

      // Two characters, but the debounce has not elapsed yet
      fireEvent.change(input, { target: { value: 'ab' } });
      expect(mockSearchConversations).not.toHaveBeenCalled();

      // Advance 300ms, which fires one IndexedDB search
      await act(async () => {
        vi.advanceTimersByTime(300);
        await Promise.resolve();
      });
      expect(mockSearchConversations).toHaveBeenCalledWith('ab');
    } finally {
      vi.useRealTimers();
    }
  });

  // Safety net: with no user gesture, no destructive store op should run, which would mean an action
  // was wired to mount instead
  it('renders without calling any destructive op', async () => {
    setState({ conversations: [makeConv({ id: 'c1', title: 'Idle' })] });
    renderList();
    await waitFor(() => expect(screen.getByText('Idle')).toBeTruthy());
    expect(mockDeleteConversation).not.toHaveBeenCalled();
    expect(mockDeleteConversations).not.toHaveBeenCalled();
    expect(mockMoveConversationToFolder).not.toHaveBeenCalled();
    expect(mockUpdateConversationTitle).not.toHaveBeenCalled();
    expect(routerPush).not.toHaveBeenCalled();
  });
});
