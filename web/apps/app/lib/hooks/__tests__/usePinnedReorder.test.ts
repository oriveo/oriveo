import { describe, it, expect, vi } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { usePinnedReorder } from '../usePinnedReorder';
import { CONVERSATION_DRAG_MIME } from '../../constants/drag';

function makeDragEvent() {
  const store: Record<string, string> = {};
  const dataTransfer = {
    effectAllowed: '',
    dropEffect: '',
    setData: vi.fn((type: string, val: string) => { store[type] = val; }),
    getData: vi.fn((type: string) => store[type] ?? ''),
    get types() { return Object.keys(store); },
  };
  return { preventDefault: vi.fn(), dataTransfer } as unknown as React.DragEvent;
}

describe('usePinnedReorder', () => {
  const pinned = ['a', 'b', 'c', 'd'];

  it('handleDragStart writes the conversation ID under CONVERSATION_DRAG_MIME, not text/plain', () => {
    const setOrder = vi.fn();
    const { result } = renderHook(() => usePinnedReorder(pinned, setOrder));
    const e = makeDragEvent();
    act(() => result.current.handleDragStart(e, 'b'));
    expect(e.dataTransfer.setData).toHaveBeenCalledWith(CONVERSATION_DRAG_MIME, 'b');
    expect(e.dataTransfer.setData).not.toHaveBeenCalledWith('text/plain', expect.anything());
    expect(result.current.draggedId).toBe('b');
  });

  it('handleDrop: reorders to the drop target and writes the order back', () => {
    const setOrder = vi.fn();
    const { result } = renderHook(() => usePinnedReorder(pinned, setOrder));
    const e1 = makeDragEvent();
    act(() => result.current.handleDragStart(e1, 'b'));
    const e2 = makeDragEvent();
    act(() => result.current.handleDrop(e2, 'd'));
    expect(setOrder).toHaveBeenCalledWith(['a', 'c', 'd', 'b']);
    expect(result.current.draggedId).toBeNull();
  });

  it('handleDrop: no write-back when source equals target or there is no drag source', () => {
    const setOrder = vi.fn();
    const { result } = renderHook(() => usePinnedReorder(pinned, setOrder));
    act(() => result.current.handleDrop(makeDragEvent(), 'a')); // no draggedId
    expect(setOrder).not.toHaveBeenCalled();
    act(() => result.current.handleDragStart(makeDragEvent(), 'b'));
    act(() => result.current.handleDrop(makeDragEvent(), 'b')); // source == target
    expect(setOrder).not.toHaveBeenCalled();
  });

  it('reorderByKeyboard: top/up/down write back the right order', () => {
    const setOrder = vi.fn();
    const { result } = renderHook(() => usePinnedReorder(pinned, setOrder));
    act(() => result.current.reorderByKeyboard('c', 'top'));
    expect(setOrder).toHaveBeenLastCalledWith(['c', 'a', 'b', 'd']);
    act(() => result.current.reorderByKeyboard('c', 'up'));
    expect(setOrder).toHaveBeenLastCalledWith(['a', 'c', 'b', 'd']);
    act(() => result.current.reorderByKeyboard('b', 'down'));
    expect(setOrder).toHaveBeenLastCalledWith(['a', 'c', 'b', 'd']);
  });

  it('reorderByKeyboard: boundary no-ops do not write back', () => {
    const setOrder = vi.fn();
    const { result } = renderHook(() => usePinnedReorder(pinned, setOrder));
    act(() => result.current.reorderByKeyboard('a', 'up'));
    act(() => result.current.reorderByKeyboard('a', 'top'));
    act(() => result.current.reorderByKeyboard('d', 'down'));
    expect(setOrder).not.toHaveBeenCalled();
  });
});
