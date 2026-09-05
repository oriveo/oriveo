import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Dialog } from './Dialog';

describe('Dialog', () => {
  beforeEach(() => {
    vi.stubGlobal('requestAnimationFrame', (callback: FrameRequestCallback) => {
      callback(0);
      return 1;
    });
  });

  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
  });

  it('does not close from overlay click or Escape when dismissible is false', () => {
    const onClose = vi.fn();

    render(
      <Dialog open onClose={onClose} dismissible={false}>
        <button type="button">Action</button>
      </Dialog>,
    );

    fireEvent.click(screen.getByRole('dialog'));
    fireEvent.keyDown(document, { key: 'Escape' });

    expect(onClose).not.toHaveBeenCalled();
  });

  it('traps focus inside the dialog when tabbing', () => {
    render(
      <Dialog open>
        <button type="button">First</button>
        <button type="button">Last</button>
      </Dialog>,
    );

    const first = screen.getByRole('button', { name: 'First' });
    const last = screen.getByRole('button', { name: 'Last' });

    first.focus();
    fireEvent.keyDown(document, { key: 'Tab', shiftKey: true });
    expect(document.activeElement).toBe(last);

    last.focus();
    fireEvent.keyDown(document, { key: 'Tab' });
    expect(document.activeElement).toBe(first);
  });

  it('supports a wide flush shell for custom modal surfaces', () => {
    render(
      <Dialog open size="xl" padded={false}>
        <button type="button">Action</button>
      </Dialog>,
    );

    const shell = screen.getByRole('button', { name: 'Action' }).parentElement;
    expect(shell?.className).toContain('dialogXl');
    expect(shell?.className).toContain('dialogFlush');
  });

  it('applies optional overlay and shell classes without changing defaults', () => {
    render(
      <Dialog
        open
        overlayClassName="walletOverlay"
        className="walletShell"
        ariaLabelledBy="wallet-title"
      >
        <h2 id="wallet-title">Wallet</h2>
        <button type="button">Action</button>
      </Dialog>,
    );

    const overlay = screen.getByRole('dialog');
    const shell = screen.getByRole('button', { name: 'Action' }).parentElement;
    expect(overlay.className).toContain('walletOverlay');
    expect(overlay.getAttribute('aria-labelledby')).toBe('wallet-title');
    expect(shell?.className).toContain('walletShell');
  });

  it('keeps default class names and labelling attributes clean', () => {
    render(
      <Dialog open>
        <button type="button">Action</button>
      </Dialog>,
    );

    const overlay = screen.getByRole('dialog');
    const shell = screen.getByRole('button', { name: 'Action' }).parentElement;
    expect(overlay.className).not.toContain('undefined');
    expect(overlay.className).not.toMatch(/\s{2,}|^\s|\s$/);
    expect(overlay.getAttribute('aria-labelledby')).toBeNull();
    expect(shell?.className).not.toContain('undefined');
    expect(shell?.className).not.toMatch(/\s{2,}|^\s|\s$/);
  });

  it('keeps an animated dialog mounted in its closed state until the shell animation ends', () => {
    const { rerender } = render(
      <Dialog open exitDurationMs={220}>
        <button type="button">Action</button>
      </Dialog>,
    );

    rerender(
      <Dialog open={false} exitDurationMs={220}>
        <button type="button">Action</button>
      </Dialog>,
    );

    const overlay = screen.getByRole('dialog', { hidden: true });
    const shell = overlay.firstElementChild as HTMLElement;
    expect(overlay.getAttribute('data-state')).toBe('closed');
    expect(shell.getAttribute('data-state')).toBe('closed');

    fireEvent.animationEnd(shell);
    expect(screen.queryByRole('dialog', { hidden: true })).toBeNull();
  });

  it('does not restore or replace focus when dismissibility callbacks change while open', () => {
    const opener = document.createElement('button');
    opener.textContent = 'Open';
    document.body.appendChild(opener);
    opener.focus();

    const { rerender } = render(
      <Dialog open onClose={vi.fn()}>
        <button type="button">First</button>
        <button type="button">Second</button>
      </Dialog>,
    );

    const second = screen.getByRole('button', { name: 'Second' });
    second.focus();

    rerender(
      <Dialog open onClose={vi.fn()} dismissible={false}>
        <button type="button">First</button>
        <button type="button">Second</button>
      </Dialog>,
    );

    expect(document.activeElement).toBe(second);
    opener.remove();
  });

  it('pulls focus back inside when Tab starts outside the open dialog', () => {
    const outside = document.createElement('button');
    outside.textContent = 'Outside';
    document.body.appendChild(outside);

    render(
      <Dialog open>
        <button type="button">First</button>
        <button type="button">Last</button>
      </Dialog>,
    );

    outside.focus();
    fireEvent.keyDown(document, { key: 'Tab' });

    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'First' }));
    outside.remove();
  });

  it('supports targeting the initial conversion control instead of the first close button', () => {
    render(
      <Dialog open initialFocusSelector="[data-initial-focus]">
        <button type="button">Close</button>
        <button type="button" data-initial-focus>Recommended package</button>
      </Dialog>,
    );

    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Recommended package' }));
  });

  it('keeps body scrolling locked through an animated exit and restores the previous value', () => {
    document.body.style.overflow = 'clip';
    const { rerender } = render(
      <Dialog open exitDurationMs={220} lockBodyScroll>
        <button type="button">Action</button>
      </Dialog>,
    );

    expect(document.body.style.overflow).toBe('hidden');

    rerender(
      <Dialog open={false} exitDurationMs={220} lockBodyScroll>
        <button type="button">Action</button>
      </Dialog>,
    );

    expect(document.body.style.overflow).toBe('hidden');
    const overlay = screen.getByRole('dialog', { hidden: true });
    fireEvent.animationEnd(overlay.firstElementChild as HTMLElement);
    expect(document.body.style.overflow).toBe('clip');
    document.body.style.overflow = '';
  });

  it('reapplies the preferred initial focus after a full animated exit and reopen', () => {
    const { rerender } = render(
      <Dialog open exitDurationMs={220} initialFocusSelector="[data-initial-focus]">
        <button type="button">Close</button>
        <button type="button" data-initial-focus>Recommended package</button>
      </Dialog>,
    );
    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Recommended package' }));

    rerender(
      <Dialog open={false} exitDurationMs={220} initialFocusSelector="[data-initial-focus]">
        <button type="button">Close</button>
        <button type="button" data-initial-focus>Recommended package</button>
      </Dialog>,
    );
    const closingDialog = screen.getByRole('dialog', { hidden: true });
    fireEvent.animationEnd(closingDialog.firstElementChild as HTMLElement);

    rerender(
      <Dialog open exitDurationMs={220} initialFocusSelector="[data-initial-focus]">
        <button type="button">Close</button>
        <button type="button" data-initial-focus>Recommended package</button>
      </Dialog>,
    );
    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Recommended package' }));
  });
});
