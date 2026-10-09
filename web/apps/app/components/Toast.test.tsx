// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { showRichToast, showToast, TOAST_ACCENT, ToastContainer, type ToastVariant } from './Toast';

afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

function capsule() {
  return screen.getByRole('alert');
}

describe('ToastContainer capsule', () => {
  const cases: Array<[ToastVariant | undefined, string, string]> = [
    ['success', 'success', 'var(--o-success)'],
    ['error', 'error', 'var(--o-error)'],
    ['warning', 'warning', 'var(--o-warning)'],
    ['info', 'info', 'var(--o-info)'],
    ['removed', 'removed', 'var(--o-text-secondary)'],
    [undefined, 'neutral', 'var(--o-text-secondary)'],
  ];

  it.each(cases)('variant %s renders %s icon with its accent', (variant, style, accent) => {
    render(<ToastContainer />);
    act(() => showToast('hello', 3000, undefined, variant));

    const el = capsule();
    expect(el.getAttribute('data-variant')).toBe(style);
    expect(el.style.getPropertyValue('--toast-accent')).toBe(accent);
    expect(TOAST_ACCENT[style as keyof typeof TOAST_ACCENT]).toBe(accent);
    const icon = el.querySelector(`[data-toast-icon="${style}"]`);
    expect(icon).not.toBeNull();
    expect(icon?.querySelector('svg')).not.toBeNull();
    expect(el.textContent).toContain('hello');
  });

  it('marks newline-joined messages as multiline and leaves single-line ones alone', () => {
    render(<ToastContainer />);
    act(() => showToast('plain'));
    expect(capsule().hasAttribute('data-multiline')).toBe(false);

    act(() => showToast('first\nsecond\nthird'));
    expect(capsule().getAttribute('data-multiline')).toBe('true');
    expect(capsule().textContent).toBe('first\nsecond\nthird');
  });

  it('has no always-visible close button', () => {
    render(<ToastContainer />);
    act(() => showToast('plain'));
    expect(screen.queryAllByRole('button')).toHaveLength(0);
    expect(capsule().querySelector('[data-toast-divider]')).toBeNull();
  });

  it('renders divider + text action, runs the action once and dismisses', () => {
    const onUndo = vi.fn();
    render(<ToastContainer />);
    act(() => showToast('Removed GPT-4o', 4000, onUndo, 'removed', 'Undo'));

    const el = capsule();
    expect(el.hasAttribute('data-has-action')).toBe(true);
    expect(el.querySelector('[data-toast-divider]')).not.toBeNull();
    const action = screen.getByRole('button', { name: 'Undo' });
    fireEvent.click(action);

    expect(onUndo).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole('alert')).toBeNull();
  });

  it('falls back to common.undo label when none is given', () => {
    render(<ToastContainer />);
    act(() => showToast('x', 3000, vi.fn()));
    expect(screen.getByRole('button', { name: 'undo' })).toBeTruthy();
  });

  it('clicking the capsule body dismisses without running the action', () => {
    const onUndo = vi.fn();
    render(<ToastContainer />);
    act(() => showToast('msg', 3000, onUndo, 'success'));
    fireEvent.click(capsule());
    expect(screen.queryByRole('alert')).toBeNull();
    expect(onUndo).not.toHaveBeenCalled();
  });

  it('auto-dismisses after the duration', () => {
    vi.useFakeTimers();
    render(<ToastContainer />);
    act(() => showToast('bye', 1000, undefined, 'info'));
    expect(capsule()).toBeTruthy();
    act(() => { vi.advanceTimersByTime(1000); });
    expect(screen.queryByRole('alert')).toBeNull();
  });

  it('showRichToast renders inside the same capsule', () => {
    render(<ToastContainer />);
    act(() => showRichToast(<strong data-testid="rich">rich</strong>, 4000, 'warning'));
    const el = capsule();
    expect(el.getAttribute('data-variant')).toBe('warning');
    expect(el.contains(screen.getByTestId('rich'))).toBe(true);
  });
});
