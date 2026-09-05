import { describe, it, expect, vi, afterEach } from 'vitest';
import { renderHook } from '@testing-library/react';
import { useRef } from 'react';
import { useDismissOnOutsideClick } from '../useDismissOnOutsideClick';

afterEach(() => {
  document.body.innerHTML = '';
});

describe('useDismissOnOutsideClick', () => {
  it('a click outside the container fires onDismiss, a click inside does not', () => {
    const inside = document.createElement('div');
    const outside = document.createElement('div');
    document.body.append(inside, outside);
    const onDismiss = vi.fn();
    renderHook(() => {
      const ref = useRef<HTMLDivElement>(inside);
      useDismissOnOutsideClick(ref, { onDismiss });
    });

    outside.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }));
    expect(onDismiss).toHaveBeenCalledTimes(1);

    inside.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }));
    expect(onDismiss).toHaveBeenCalledTimes(1);
  });

  it('with closeOnEscape=true, Escape fires onDismiss', () => {
    const el = document.createElement('div');
    document.body.append(el);
    const onDismiss = vi.fn();
    renderHook(() => {
      const ref = useRef<HTMLDivElement>(el);
      useDismissOnOutsideClick(ref, { onDismiss, closeOnEscape: true });
    });

    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
    expect(onDismiss).toHaveBeenCalled();
  });

  it('Escape is not listened for by default', () => {
    const el = document.createElement('div');
    document.body.append(el);
    const onDismiss = vi.fn();
    renderHook(() => {
      const ref = useRef<HTMLDivElement>(el);
      useDismissOnOutsideClick(ref, { onDismiss });
    });

    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
    expect(onDismiss).not.toHaveBeenCalled();
  });
});
