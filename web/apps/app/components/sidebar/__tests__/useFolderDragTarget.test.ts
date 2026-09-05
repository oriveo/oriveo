import { describe, it, expect, vi, beforeEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import type { Conversation, Folder } from '@oriveo/shared';
import { CONVERSATION_DRAG_MIME } from '../../../lib/constants/drag';

const { mockMove, mockToast, mockVanillaStore } = vi.hoisted(() => ({
  mockMove: vi.fn(),
  mockToast: vi.fn(),
  mockVanillaStore: {},
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string, params?: Record<string, unknown>) =>
    params ? `${key}:${JSON.stringify(params)}` : key,
}));
vi.mock('../../../providers/StoreProvider', () => ({
  getVanillaStore: () => mockVanillaStore,
}));
vi.mock('../../../lib/core/folder-ops', () => ({
  moveConversationToFolder: (...args: unknown[]) => mockMove(...args),
}));
vi.mock('../../Toast', () => ({
  showToast: (...args: unknown[]) => mockToast(...args),
}));

import { useFolderDragTarget } from '../useFolderDragTarget';

const folder = { id: 'f1', name: 'Work' } as Folder;
const conv = (id: string): Conversation => ({ id } as Conversation);

function dropEvent(data: Record<string, string>) {
  return {
    preventDefault: vi.fn(),
    dataTransfer: {
      dropEffect: '',
      getData: (type: string) => data[type] ?? '',
      get types() { return Object.keys(data); },
    },
  } as unknown as React.DragEvent;
}

describe('useFolderDragTarget', () => {
  beforeEach(() => vi.clearAllMocks());

  it('drop reads CONVERSATION_DRAG_MIME, moves into the folder and shows a toast', () => {
    const { result } = renderHook(() => useFolderDragTarget([], folder));
    act(() => result.current.handleDrop(dropEvent({ [CONVERSATION_DRAG_MIME]: 'c9' })));
    expect(mockMove).toHaveBeenCalledWith(mockVanillaStore, 'c9', 'f1');
    expect(mockToast).toHaveBeenCalled();
  });

  it('drop from outside (no conversation MIME) moves nothing', () => {
    const { result } = renderHook(() => useFolderDragTarget([], folder));
    act(() => result.current.handleDrop(dropEvent({ 'text/plain': 'random text' })));
    expect(mockMove).not.toHaveBeenCalled();
  });

  it('drop is skipped when the conversation is already in this folder', () => {
    const { result } = renderHook(() => useFolderDragTarget([conv('c9')], folder));
    act(() => result.current.handleDrop(dropEvent({ [CONVERSATION_DRAG_MIME]: 'c9' })));
    expect(mockMove).not.toHaveBeenCalled();
  });

  it('dragOver only highlights and calls preventDefault for a drag carrying the conversation MIME', () => {
    const { result } = renderHook(() => useFolderDragTarget([], folder));
    const e = dropEvent({ [CONVERSATION_DRAG_MIME]: 'c9' });
    act(() => result.current.handleDragOver(e));
    expect(e.preventDefault).toHaveBeenCalled();
    expect(result.current.dragOver).toBe(true);
  });

  it('dragOver from outside neither highlights nor calls preventDefault', () => {
    const { result } = renderHook(() => useFolderDragTarget([], folder));
    const e = dropEvent({ 'text/plain': 'x', Files: '' });
    act(() => result.current.handleDragOver(e));
    expect(e.preventDefault).not.toHaveBeenCalled();
    expect(result.current.dragOver).toBe(false);
  });
});
