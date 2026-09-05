import { describe, it, expect } from 'vitest';
import { movePinnedToIndex, movePinnedByKeyboard } from '../pinned-reorder';

describe('movePinnedToIndex', () => {
  it('moves the element to the target index (drag semantics: remove the source + insert at the target)', () => {
    expect(movePinnedToIndex(['a', 'b', 'c', 'd'], 'b', 3)).toEqual(['a', 'c', 'd', 'b']);
    expect(movePinnedToIndex(['a', 'b', 'c', 'd'], 'c', 0)).toEqual(['c', 'a', 'b', 'd']);
  });

  it('source == target index / not found / out of range -> null', () => {
    expect(movePinnedToIndex(['a', 'b', 'c'], 'b', 1)).toBeNull(); // no change
    expect(movePinnedToIndex(['a', 'b', 'c'], 'x', 0)).toBeNull(); // does not exist
    expect(movePinnedToIndex(['a', 'b', 'c'], 'a', -1)).toBeNull(); // below the lower bound
    expect(movePinnedToIndex(['a', 'b', 'c'], 'a', 3)).toBeNull(); // above the upper bound
  });

  it('does not modify the input array', () => {
    const input = ['a', 'b', 'c'];
    movePinnedToIndex(input, 'a', 2);
    expect(input).toEqual(['a', 'b', 'c']);
  });
});

describe('movePinnedByKeyboard', () => {
  const ids = ['a', 'b', 'c', 'd'];

  it('top: move to the top', () => {
    expect(movePinnedByKeyboard(ids, 'c', 'top')).toEqual(['c', 'a', 'b', 'd']);
  });

  it('up: move up one place', () => {
    expect(movePinnedByKeyboard(ids, 'c', 'up')).toEqual(['a', 'c', 'b', 'd']);
  });

  it('down: move down one place', () => {
    expect(movePinnedByKeyboard(ids, 'b', 'down')).toEqual(['a', 'c', 'b', 'd']);
  });

  it('boundary no-op: first item up/top, last item down, unknown id -> null', () => {
    expect(movePinnedByKeyboard(ids, 'a', 'up')).toBeNull();
    expect(movePinnedByKeyboard(ids, 'a', 'top')).toBeNull();
    expect(movePinnedByKeyboard(ids, 'd', 'down')).toBeNull();
    expect(movePinnedByKeyboard(ids, 'x', 'up')).toBeNull();
  });
});
