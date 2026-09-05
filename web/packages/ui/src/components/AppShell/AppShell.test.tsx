import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { AppShell, MIN_SIDEBAR_WIDTH, MAX_SIDEBAR_WIDTH, DEFAULT_SIDEBAR_WIDTH } from './AppShell';

// The pointer drag path (pointerdown -> pointermove -> pointerup) is hard to simulate reliably
// under jsdom: the PointerEvent constructor behaves differently across jsdom versions, and the
// events from testing-library fireEvent.pointerXxx carry no clientX. That path is verified by hand
// in a browser. What is covered here: DOM rendering, CSS variable passing, the keyboard and
// double-click commit logic, and the clamp boundaries.

describe('AppShell sidebar resizer', () => {
  afterEach(() => cleanup());

  it('does not render the resizer when onSidebarWidthChange is omitted', () => {
    render(
      <AppShell sidebarOpen>
        <div>main</div>
      </AppShell>,
    );
    expect(screen.queryByRole('separator')).toBeNull();
  });

  it('renders the resizer with min/max/value when controlled', () => {
    render(
      <AppShell
        sidebarOpen
        sidebarWidth={340}
        onSidebarWidthChange={() => {}}
        resizerLabel="Resize sidebar"
      >
        <div>main</div>
      </AppShell>,
    );
    const sep = screen.getByRole('separator', { name: 'Resize sidebar' });
    expect(sep.getAttribute('aria-valuemin')).toBe(String(MIN_SIDEBAR_WIDTH));
    expect(sep.getAttribute('aria-valuemax')).toBe(String(MAX_SIDEBAR_WIDTH));
    expect(sep.getAttribute('aria-valuenow')).toBe('340');
    expect(sep.getAttribute('aria-orientation')).toBe('vertical');
  });

  it('hides the resizer when sidebar is collapsed', () => {
    render(
      <AppShell sidebarOpen={false} onSidebarWidthChange={() => {}}>
        <div>main</div>
      </AppShell>,
    );
    expect(screen.queryByRole('separator')).toBeNull();
  });

  it('collapses the grid column in the same turn as hiding the sidebar', () => {
    const { container, rerender } = render(
      <AppShell sidebarOpen onToggleSidebar={() => {}}>
        <div>main</div>
      </AppShell>,
    );
    const shell = container.firstChild as HTMLElement;
    expect(shell.getAttribute('data-sidebar-open')).toBe('true');
    expect(shell.hasAttribute('data-sidebar-layout')).toBe(false);

    rerender(
      <AppShell sidebarOpen={false} onToggleSidebar={() => {}}>
        <div>main</div>
      </AppShell>,
    );
    expect(shell.getAttribute('data-sidebar-open')).toBe('false');
    expect(shell.hasAttribute('data-sidebar-layout')).toBe(false);
  });

  it('exposes width as a CSS variable on the shell root', () => {
    const { container } = render(
      <AppShell sidebarOpen sidebarWidth={420} onSidebarWidthChange={() => {}}>
        <div>main</div>
      </AppShell>,
    );
    const shell = container.firstChild as HTMLElement;
    expect(shell.style.getPropertyValue('--o-sidebar-width-user')).toBe('420px');
  });

  it('does not set the CSS variable when no width is provided', () => {
    const { container } = render(
      <AppShell sidebarOpen onSidebarWidthChange={() => {}}>
        <div>main</div>
      </AppShell>,
    );
    const shell = container.firstChild as HTMLElement;
    expect(shell.style.getPropertyValue('--o-sidebar-width-user')).toBe('');
  });

  it('resets width to default on double click', () => {
    const onChange = vi.fn();
    render(
      <AppShell sidebarOpen sidebarWidth={420} onSidebarWidthChange={onChange}>
        <div>main</div>
      </AppShell>,
    );
    fireEvent.doubleClick(screen.getByRole('separator'));
    expect(onChange).toHaveBeenCalledTimes(1);
    expect(onChange).toHaveBeenCalledWith(DEFAULT_SIDEBAR_WIDTH);
  });

  it('steps width via ArrowLeft / ArrowRight', () => {
    const onChange = vi.fn();
    render(
      <AppShell sidebarOpen sidebarWidth={300} onSidebarWidthChange={onChange}>
        <div>main</div>
      </AppShell>,
    );
    const sep = screen.getByRole('separator');
    fireEvent.keyDown(sep, { key: 'ArrowLeft' });
    expect(onChange).toHaveBeenLastCalledWith(284);
    fireEvent.keyDown(sep, { key: 'ArrowRight' });
    expect(onChange).toHaveBeenLastCalledWith(316);
  });

  it('jumps to min/max via Home / End', () => {
    const onChange = vi.fn();
    render(
      <AppShell sidebarOpen sidebarWidth={300} onSidebarWidthChange={onChange}>
        <div>main</div>
      </AppShell>,
    );
    const sep = screen.getByRole('separator');
    fireEvent.keyDown(sep, { key: 'Home' });
    expect(onChange).toHaveBeenLastCalledWith(MIN_SIDEBAR_WIDTH);
    fireEvent.keyDown(sep, { key: 'End' });
    expect(onChange).toHaveBeenLastCalledWith(MAX_SIDEBAR_WIDTH);
  });

  it('clamps keyboard steps below min and above max', () => {
    const onChange = vi.fn();
    render(
      <AppShell sidebarOpen sidebarWidth={MIN_SIDEBAR_WIDTH} onSidebarWidthChange={onChange}>
        <div>main</div>
      </AppShell>,
    );
    fireEvent.keyDown(screen.getByRole('separator'), { key: 'ArrowLeft' });
    expect(onChange).toHaveBeenLastCalledWith(MIN_SIDEBAR_WIDTH);

    onChange.mockReset();
    cleanup();

    render(
      <AppShell sidebarOpen sidebarWidth={MAX_SIDEBAR_WIDTH} onSidebarWidthChange={onChange}>
        <div>main</div>
      </AppShell>,
    );
    fireEvent.keyDown(screen.getByRole('separator'), { key: 'ArrowRight' });
    expect(onChange).toHaveBeenLastCalledWith(MAX_SIDEBAR_WIDTH);
  });

  it('starts resize state on pointerdown (verifies window listener registration path)', () => {
    render(
      <AppShell sidebarOpen sidebarWidth={300} onSidebarWidthChange={() => {}}>
        <div>main</div>
      </AppShell>,
    );
    const sep = screen.getByRole('separator');
    expect(sep.getAttribute('data-active')).toBeNull();
    fireEvent.pointerDown(sep, { button: 0 });
    expect(sep.getAttribute('data-active')).toBe('true');
  });
});

describe('AppShell mobile app chrome', () => {
  afterEach(() => cleanup());

  const navItems = [
    { label: 'Home', href: '/chat', icon: <span aria-hidden="true">H</span> },
    { label: 'Providers', href: '/providers', icon: <span aria-hidden="true">P</span> },
    { label: 'Settings', href: '/settings', icon: <span aria-hidden="true">S</span> },
  ];

  it('renders a dedicated mobile tab bar outside the drawer', () => {
    render(
      <AppShell navItems={navItems} activePath="/providers" sidebarOpen={false}>
        <div>main</div>
      </AppShell>,
    );

    const navs = screen.getAllByRole('navigation', { name: 'Main navigation' });
    expect(navs).toHaveLength(2);
    expect(navs[0].className).toContain('sidebarNav');
    expect(navs[1].className).toContain('mobileTabBar');
    expect(navs[1].querySelectorAll('a,button')).toHaveLength(3);
    expect(navs[1].textContent).toContain('Providers');
    expect(navs[1].querySelector('[aria-current="page"]')?.getAttribute('href')).toBe('/providers');
  });

  it('keeps mobile tab navigation available when the sidebar drawer is open', () => {
    const onNavigate = vi.fn();
    render(
      <AppShell
        navItems={navItems}
        activePath="/chat"
        sidebarOpen
        onNavigate={onNavigate}
      >
        <div>main</div>
      </AppShell>,
    );

    const mobileTabBar = screen.getAllByRole('navigation', { name: 'Main navigation' })[1];
    fireEvent.click(mobileTabBar.querySelectorAll('button')[2]);
    expect(onNavigate).toHaveBeenCalledWith('/settings');
  });

  it('can keep the overlay drawer closed independently from the desktop sidebar state', () => {
    const { container } = render(
      <AppShell
        navItems={navItems}
        activePath="/chat"
        sidebarOpen
        overlaySidebarOpen={false}
      >
        <div>main</div>
      </AppShell>,
    );

    const shell = container.firstChild as HTMLElement;
    expect(shell.getAttribute('data-sidebar-open')).toBe('true');
    expect(shell.getAttribute('data-overlay-sidebar-open')).toBe('false');
    expect(container.querySelector('.overlay')).toBeNull();
  });

  it('marks chat root as the mobile home surface', () => {
    const { container } = render(
      <AppShell
        navItems={navItems}
        activePath="/chat"
        sidebarOpen={false}
        mobileHomeMode
      >
        <div>main</div>
      </AppShell>,
    );

    expect((container.firstChild as HTMLElement).getAttribute('data-mobile-home')).toBe('true');
  });

  it('marks full-screen mobile surfaces when the bottom tab bar is hidden', () => {
    const { container } = render(
      <AppShell
        navItems={navItems}
        activePath="/chat"
        sidebarOpen={false}
        hideMobileTabBar
      >
        <div>main</div>
      </AppShell>,
    );

    expect((container.firstChild as HTMLElement).getAttribute('data-mobile-tabbar-hidden')).toBe('true');
    expect(screen.queryByRole('navigation', { name: 'Main navigation' })?.className).not.toContain('mobileTabBar');
  });

  it('renders the notes entry in the sidebar actions (not the dock) with active state', () => {
    const { container } = render(
      <AppShell
        navItems={navItems}
        notesEntry={{ label: 'Notes', href: '/notes', icon: <span aria-hidden="true">N</span> }}
        activePath="/notes"
        sidebarOpen
      >
        <div>main</div>
      </AppShell>,
    );

    // The notes entry sits in the new conversation action area and highlights the current state on /notes
    const actions = container.querySelector('.sidebarActions');
    expect(actions?.textContent).toContain('Notes');
    expect(actions?.querySelector('[aria-current="page"]')?.textContent).toContain('Notes');

    // Neither the bottom dock nor the mobile tab bar contains notes
    const navs = screen.getAllByRole('navigation', { name: 'Main navigation' });
    expect(navs.every((nav) => !nav.textContent?.includes('Notes'))).toBe(true);
  });
});

describe('AppShell responsive CSS', () => {
  it('uses semantic chrome tokens for glass navigation instead of module dark overrides', () => {
    const cssPath = join(dirname(fileURLToPath(import.meta.url)), 'AppShell.module.css');
    const css = readFileSync(cssPath, 'utf8');

    expect(css).toContain('var(--o-shell-nav-bg)');
    expect(css).toContain('var(--o-shell-nav-active-bg)');
    expect(css).toContain('--o-shell-nav-sheen');
    expect(css).toContain('--o-shell-nav-bg:');
    expect(css).toContain('color-mix(in srgb, var(--o-surface) 96%, transparent)');
    expect(css).toContain('--o-shell-nav-active-bg:');
    expect(css).toContain('color-mix(in srgb, var(--o-text) 12%, var(--o-surface))');
    expect(css).toContain('.sidebarNav::before');
    expect(css).not.toContain(":global(html[data-theme='dark']) .sidebarNav");
    expect(css).not.toContain(":global(html[data-theme='dark']) .navItemActive");
  });

  it('keeps the sidebar visually connected to the chat ambient surface', () => {
    const cssPath = join(dirname(fileURLToPath(import.meta.url)), 'AppShell.module.css');
    const css = readFileSync(cssPath, 'utf8');

    expect(css).toContain('var(--o-shell-sidebar-bg)');
    expect(css).toContain('var(--o-shell-sidebar-pattern)');
    expect(css).toContain('var(--o-shell-sidebar-pattern-opacity)');
    expect(css).toContain('--o-shell-sidebar-glass-blur');
    expect(css).toContain('--o-shell-sidebar-edge-fade');
    expect(css).toContain('var(--o-shell-sidebar-edge-fade)');
    expect(css).toContain('.sidebar::before');
    expect(css).not.toContain('.sidebar::after');
    const sidebarRuleStart = css.indexOf('.sidebar {');
    const sidebarRuleEnd = css.indexOf('\n}', sidebarRuleStart);
    expect(sidebarRuleStart).toBeGreaterThanOrEqual(0);
    const sidebarRule = css.slice(sidebarRuleStart, sidebarRuleEnd);
    expect(sidebarRule).toContain('background: var(--o-shell-sidebar-bg);');
    expect(sidebarRule).toContain('backdrop-filter: var(--o-shell-sidebar-glass-blur);');
    expect(sidebarRule).toContain('-webkit-backdrop-filter: var(--o-shell-sidebar-glass-blur);');
    expect(sidebarRule).toContain('border-inline-end: 0;');
    expect(css).not.toContain(":global(html[data-theme='dark']) .sidebar");
  });

  it('keeps the desktop dock quieter than the mobile floating dock', () => {
    const cssPath = join(dirname(fileURLToPath(import.meta.url)), 'AppShell.module.css');
    const css = readFileSync(cssPath, 'utf8');

    expect(css).toContain('--o-shell-nav-sidebar-shadow');
    expect(css).toContain('box-shadow: var(--o-shell-nav-sidebar-shadow);');
    expect(css).toContain('box-shadow: var(--o-shell-nav-shadow);');
  });

  it('does not draw an extra divider above the sidebar dock', () => {
    const cssPath = join(dirname(fileURLToPath(import.meta.url)), 'AppShell.module.css');
    const css = readFileSync(cssPath, 'utf8');
    const bottomCardRuleStart = css.indexOf('.sidebarBottomCard {');
    const bottomCardRuleEnd = css.indexOf('\n}', bottomCardRuleStart);

    expect(bottomCardRuleStart).toBeGreaterThanOrEqual(0);
    expect(css.slice(bottomCardRuleStart, bottomCardRuleEnd)).not.toContain('border-top');
  });

  it('keeps overlay breakpoints on a single content column when the desktop sidebar is collapsed', () => {
    const cssPath = join(dirname(fileURLToPath(import.meta.url)), 'AppShell.module.css');
    const css = readFileSync(cssPath, 'utf8');
    const collapsedRuleIndex = css.indexOf(".shell[data-sidebar-open='false']");
    const overlayMediaIndex = css.indexOf('@media (max-width: 1023px)');
    const overlayCollapsedOverrideIndex = css.indexOf(".shell[data-sidebar-open='false']", overlayMediaIndex);

    expect(collapsedRuleIndex).toBeGreaterThanOrEqual(0);
    expect(overlayMediaIndex).toBeGreaterThan(collapsedRuleIndex);
    expect(overlayCollapsedOverrideIndex).toBeGreaterThan(overlayMediaIndex);
    expect(css.slice(overlayCollapsedOverrideIndex, overlayCollapsedOverrideIndex + 180)).toContain('grid-template-columns: 1fr');
  });

  it('does not interpolate grid-template-columns while the desktop sidebar slides', () => {
    const cssPath = join(dirname(fileURLToPath(import.meta.url)), 'AppShell.module.css');
    const css = readFileSync(cssPath, 'utf8');
    const shellRuleStart = css.indexOf('.shell {');
    const shellRuleEnd = css.indexOf('\n}', shellRuleStart);
    const shellRule = css.slice(shellRuleStart, shellRuleEnd);
    const sidebarRuleStart = css.indexOf('\n.sidebar {');
    const sidebarRuleEnd = css.indexOf('\n}', sidebarRuleStart);
    const sidebarRule = css.slice(sidebarRuleStart, sidebarRuleEnd);
    const collapsedRuleStart = css.indexOf(".shell[data-sidebar-open='false'] {");
    const collapsedRuleEnd = css.indexOf('\n}', collapsedRuleStart);
    const collapsedRule = css.slice(collapsedRuleStart, collapsedRuleEnd);

    expect(shellRule).not.toContain('transition: grid-template-columns');
    expect(css).not.toMatch(/\.shell\s*\{[^}]*transition:\s*grid-template-columns/s);
    expect(collapsedRule).toContain('grid-template-columns: 0 1fr');
    expect(css).not.toContain('data-sidebar-layout');
    expect(css).not.toContain('.sidebarSlot');
    expect(sidebarRule).toContain('transition: transform var(--o-transition-normal)');
    expect(sidebarRule).toContain('width: var(--o-sidebar-width-user, var(--o-sidebar-width))');
    expect(sidebarRule).toContain('min-width: 0');
  });

  it('hides the sidebar opener on mobile tab pages so it cannot overlap page titles', () => {
    const cssPath = join(dirname(fileURLToPath(import.meta.url)), 'AppShell.module.css');
    const css = readFileSync(cssPath, 'utf8');
    const mobileMediaIndex = css.indexOf('@media (max-width: 767px)');
    const tabShellRuleIndex = css.indexOf(".shell:not([data-mobile-tabbar-hidden='true']) .sidebarOpenBtn", mobileMediaIndex);

    expect(tabShellRuleIndex).toBeGreaterThan(mobileMediaIndex);
    expect(css.slice(tabShellRuleIndex, tabShellRuleIndex + 140)).toContain('display: none');
  });
});
