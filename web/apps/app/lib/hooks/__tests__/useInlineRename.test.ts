import { describe, it, expect, vi } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import type { KeyboardEvent } from 'react';
import { useInlineRename } from '../useInlineRename';

function keyEvent(key: string, preventDefault = vi.fn()): KeyboardEvent {
  return { key, preventDefault } as unknown as KeyboardEvent;
}

describe('useInlineRename', () => {
  it('starts with editing=false; start() enters edit mode and seeds the initial value', () => {
    const onSubmit = vi.fn();
    const { result } = renderHook(() => useInlineRename({ initialValue: 'Hello', onSubmit }));
    expect(result.current.editing).toBe(false);
    act(() => result.current.start());
    expect(result.current.editing).toBe(true);
    expect(result.current.value).toBe('Hello');
  });

  it('submit ', () => {
    const onSubmit = vi.fn();
    const { result } = renderHook(() => useInlineRename({ initialValue: 'Hello', onSubmit }));
    act(() => result.current.start());
    act(() => result.current.setValue('World'));
    act(() => result.current.submit());
    expect(onSubmit).toHaveBeenCalledWith('World');
    expect(result.current.editing).toBe(false);
  });

  it('submit: neither an unchanged value nor a whitespace-only one calls back', () => {
    const onSubmit = vi.fn();
    const { result } = renderHook(() => useInlineRename({ initialValue: 'Hello', onSubmit }));
    act(() => result.current.start());
    act(() => result.current.submit()); //  
    expect(onSubmit).not.toHaveBeenCalled();
    act(() => result.current.start());
    act(() => result.current.setValue('   '));
    act(() => result.current.submit());
    expect(onSubmit).not.toHaveBeenCalled();
  });

  it('maxLength truncates the input', () => {
    const onSubmit = vi.fn();
    const { result } = renderHook(() => useInlineRename({ initialValue: '', maxLength: 5, onSubmit }));
    act(() => result.current.setValue('1234567890'));
    expect(result.current.value).toBe('12345');
  });

  it('Enter submits, Escape cancels (no callback, leaves edit mode)', () => {
    const onSubmit = vi.fn();
    const { result } = renderHook(() => useInlineRename({ initialValue: 'Hello', onSubmit }));

    act(() => result.current.start());
    act(() => result.current.setValue('World'));
    const pd = vi.fn();
    act(() => result.current.handleKeyDown(keyEvent('Enter', pd)));
    expect(pd).toHaveBeenCalled();
    expect(onSubmit).toHaveBeenCalledWith('World');

    onSubmit.mockClear();
    act(() => result.current.start());
    act(() => result.current.setValue('Another'));
    act(() => result.current.handleKeyDown(keyEvent('Escape')));
    expect(result.current.editing).toBe(false);
    expect(onSubmit).not.toHaveBeenCalled();
  });
});
