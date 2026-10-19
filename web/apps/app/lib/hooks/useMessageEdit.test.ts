// @vitest-environment jsdom
/**
 * Cancelling an edit-and-resend at the pre-send confirmation reopens that message's editor with the edited text.
 */
import { describe, expect, it, vi } from 'vitest';
import { act, renderHook } from '@testing-library/react';
import { type MessageEditReopen, useMessageEdit } from './useMessageEdit';

describe('useMessageEdit', () => {
  it('reopens the edit box with the edited text', () => {
    const onEditAndResend = vi.fn();
    const { result, rerender } = renderHook(
      ({ reopen }: { reopen?: MessageEditReopen }) => useMessageEdit('Original question', onEditAndResend, reopen),
      { initialProps: {} as { reopen?: MessageEditReopen } },
    );
    expect(result.current.editing).toBe(false);

    rerender({ reopen: { text: 'Edited question', nonce: 1 } });
    expect(result.current.editing).toBe(true);
    expect(result.current.editText).toBe('Edited question');

    // Once the signal is cleared it no longer auto-opens; submitting still resends with the edited text
    rerender({});
    act(() => result.current.handleSubmitEdit());
    expect(onEditAndResend).toHaveBeenCalledWith('Edited question');
    expect(result.current.editing).toBe(false);
  });

  it('opens on mount when the restored message carries the signal', () => {
    const { result } = renderHook(() => useMessageEdit('Original question', vi.fn(), { text: 'Edited question', nonce: 2 }));
    expect(result.current.editing).toBe(true);
    expect(result.current.editText).toBe('Edited question');
  });
});
