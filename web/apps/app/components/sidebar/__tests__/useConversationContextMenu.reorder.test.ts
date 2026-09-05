import { describe, it, expect, vi, beforeEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import type { Conversation } from '@oriveo/shared';

// t returns the key directly, which makes menu item labels easy to assert on
vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
}));
vi.mock('../../../lib/utils/conversation-item-meta', () => ({
  exportConversationMarkdown: vi.fn(),
}));

import { useConversationContextMenu } from '../useConversationContextMenu';

const conv = (id: string): Conversation => ({ id } as Conversation);

function rightClick() {
  return { preventDefault: vi.fn(), clientX: 10, clientY: 10 } as unknown as React.MouseEvent;
}

function openLabels(params: Parameters<typeof useConversationContextMenu>[0]): string[] {
  const { result } = renderHook(() => useConversationContextMenu(params));
  act(() => result.current.handleRightClick(rightClick()));
  return (result.current.menu?.items ?? []).map((i) => i.label);
}

describe('useConversationContextMenu keyboard reorder items', () => {
  beforeEach(() => {
    // ContextMenu only opens the menu on fine-pointer devices
    window.matchMedia = vi.fn().mockReturnValue({ matches: true }) as unknown as typeof window.matchMedia;
  });

  const base = { conversation: conv('b'), onDelete: vi.fn(), onStartRename: vi.fn(), onReorderPinned: vi.fn() };

  it('a pinned item in the middle shows move to top, move up and move down', () => {
    const labels = openLabels({ ...base, isPinned: true, pinnedIndex: 1, pinnedCount: 3 });
    expect(labels).toContain('moveToTop');
    expect(labels).toContain('moveUp');
    expect(labels).toContain('moveDown');
  });

  it('the first pinned item shows only move down', () => {
    const labels = openLabels({ ...base, isPinned: true, pinnedIndex: 0, pinnedCount: 3 });
    expect(labels).not.toContain('moveToTop');
    expect(labels).not.toContain('moveUp');
    expect(labels).toContain('moveDown');
  });

  it('the last pinned item shows move to top and move up, but not move down', () => {
    const labels = openLabels({ ...base, isPinned: true, pinnedIndex: 2, pinnedCount: 3 });
    expect(labels).toContain('moveToTop');
    expect(labels).toContain('moveUp');
    expect(labels).not.toContain('moveDown');
  });

  it('a single pinned item shows no reorder items', () => {
    const labels = openLabels({ ...base, isPinned: true, pinnedIndex: 0, pinnedCount: 1 });
    expect(labels).not.toContain('moveToTop');
    expect(labels).not.toContain('moveUp');
    expect(labels).not.toContain('moveDown');
  });

  it('an unpinned conversation shows no reorder items', () => {
    const labels = openLabels({ ...base, isPinned: false, pinnedIndex: undefined, pinnedCount: undefined });
    expect(labels).not.toContain('moveToTop');
    expect(labels).not.toContain('moveDown');
  });

  it('triggering move up calls onReorderPinned(id, "up")', () => {
    const onReorderPinned = vi.fn();
    const { result } = renderHook(() =>
      useConversationContextMenu({ ...base, onReorderPinned, isPinned: true, pinnedIndex: 1, pinnedCount: 3 }),
    );
    act(() => result.current.handleRightClick(rightClick()));
    const upItem = result.current.menu?.items.find((i) => i.label === 'moveUp');
    act(() => upItem?.onAction());
    expect(onReorderPinned).toHaveBeenCalledWith('b', 'up');
  });
});
