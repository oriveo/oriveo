import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { AppShell, Button, Dialog, SearchIcon } from './index';

describe('@oriveo/ui', () => {
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

  it('exports Button and forwards variant classes and click handlers', () => {
    const onClick = vi.fn();

    render(
      <Button tone="secondary" size="sm" type="button" onClick={onClick}>
        Save
      </Button>,
    );

    const button = screen.getByRole('button', { name: 'Save' });
    expect(button.className).toContain('btn');
    expect(button.className).toContain('secondary');
    expect(button.className).toContain('sm');

    fireEvent.click(button);
    expect(onClick).toHaveBeenCalledTimes(1);
  });

  it('exports Dialog and closes dismissible overlays on escape', () => {
    const onClose = vi.fn();
    const { rerender } = render(
      <Dialog open={false} onClose={onClose}>
        <button type="button">Primary action</button>
      </Dialog>,
    );

    expect(screen.queryByRole('dialog')).toBeNull();

    rerender(
      <Dialog open onClose={onClose}>
        <button type="button">Primary action</button>
      </Dialog>,
    );

    expect(screen.getByRole('dialog')).not.toBeNull();
    expect(document.activeElement?.textContent).toBe('Primary action');

    fireEvent.keyDown(document, { key: 'Escape' });
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('exports AppShell navigation primitives from the package root', () => {
    const onNavigate = vi.fn();
    const onNewChat = vi.fn();
    const onToggleSidebar = vi.fn();

    render(
      <AppShell
        activePath="/home"
        navItems={[
          { label: 'Home', href: '/home', icon: <SearchIcon size={18} /> },
        ]}
        onNavigate={onNavigate}
        onNewChat={onNewChat}
        onToggleSidebar={onToggleSidebar}
        newChatLabel="Start"
        sidebarOpen={false}
      >
        <div>Main content</div>
      </AppShell>,
    );

    const openSidebarButton = screen.getByRole('button', { name: 'Open sidebar' });
    fireEvent.click(openSidebarButton);
    expect(onToggleSidebar).toHaveBeenCalledTimes(1);

    fireEvent.click(screen.getByRole('button', { name: 'Start' }));
    expect(onNewChat).toHaveBeenCalledTimes(1);

    // AppShell renders both the sidebar nav and the mobile tab bar, each with a Home button; take
    // the first one, which is the sidebar in DOM order.
    const navButton = screen.getAllByRole('button', { name: 'Home' })[0];
    fireEvent.click(navButton);
    expect(onNavigate).toHaveBeenCalledWith('/home');
    expect(navButton.querySelector('svg')?.getAttribute('width')).toBe('18');
  });
});
