import { describe, expect, it } from 'vitest';
import {
  addStopSequence,
  canAddStopSequence,
  removeStopSequence,
  visibleStopSequence,
} from '../stop-sequence-tags';

describe('stop sequence tags', () => {
  it('invisible characters are made visible: newline ↵, tab ⇥, space ␣, and \\r\\n counts as one newline', () => {
    expect(visibleStopSequence('\n\n')).toBe('↵↵');
    expect(visibleStopSequence('a, b\tc')).toBe('a,␣b⇥c');
    expect(visibleStopSequence('x\r\ny')).toBe('x↵y');
    expect(visibleStopSequence('###')).toBe('###');
  });

  it('empty and duplicate entries are not added; a sequence is added as is, without splitting or trimming', () => {
    expect(addStopSequence(['a'], '')).toBeNull();
    expect(addStopSequence(['a'], 'a')).toBeNull();
    expect(addStopSequence(['a'], ' ')).toEqual(['a', ' ']);
    expect(addStopSequence(['a'], 'b, c\nd')).toEqual(['a', 'b, c\nd']);
  });

  it('at the limit nothing more is added and "Add" is hidden; with no declared limit there is no cap', () => {
    expect(addStopSequence(['a', 'b'], 'c', 2)).toBeNull();
    expect(canAddStopSequence(['a', 'b'], 2)).toBe(false);
    expect(canAddStopSequence(['a'], 2)).toBe(true);
    expect(canAddStopSequence(Array.from({ length: 50 }, (_, i) => String(i)))).toBe(true);
  });

  it('removes one by position', () => {
    expect(removeStopSequence(['a', 'b', 'c'], 1)).toEqual(['a', 'c']);
  });
});
