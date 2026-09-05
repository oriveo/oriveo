// @vitest-environment-options {"url":"http://app.local/chat"}

import type { ComponentType, MouseEventHandler, ReactNode } from 'react';
import { fireEvent, render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { AppShellWrapper, resolveDesktopNavigationURL } from './AppShellWrapper';

const mocks = vi.hoisted(() => ({
  pathname: '/chat',
  searchParams: new URLSearchParams(),
  isMobile: false,
  isOverlayViewport: false,
  push: vi.fn(),
  lastLinkDefaultPrevented: undefined as boolean | undefined,
}));

vi.mock('next/navigation', () => ({
  useRouter: () => ({
    push: mocks.push,
  }),
  usePathname: () => mocks.pathname,
  useSearchParams: () => mocks.searchParams,
}));

vi.mock('next/link', () => ({
  default: ({
    href,
    className,
    title,
    onClick,
    children,
    'aria-current': ariaCurrent,
  }: {
    href: string;
    className?: string;
    title?: string;
    onClick?: MouseEventHandler<HTMLAnchorElement>;
    children?: ReactNode;
    'aria-current'?: 'page';
  }) => (
    <a
      href={href}
      className={className}
      title={title}
      aria-current={ariaCurrent}
      onClick={(event) => {
        onClick?.(event);
        mocks.lastLinkDefaultPrevented = event.defaultPrevented;
        event.preventDefault();
      }}
    >
      {children}
    </a>
  ),
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
}));

vi.mock('@oriveo/ui', () => ({
  AppShell: ({
    children,
    conversationList,
    navItems,
    notesEntry,
    activePath,
    sidebarOpen,
    overlaySidebarOpen,
    mobileHomeMode,
    hideMobileTabBar,
    LinkComponent,
    onNavigate,
    onNewChat,
  }: {
    children: ReactNode;
    conversationList: ReactNode;
    navItems: Array<{ label: string; href: string }>;
    notesEntry?: { label: string; href: string };
    activePath: string;
    sidebarOpen?: boolean;
    overlaySidebarOpen?: boolean;
    mobileHomeMode?: boolean;
    hideMobileTabBar?: boolean;
    LinkComponent?: ComponentType<{
      href: string;
      prefetch?: boolean;
      className?: string;
      title?: string;
      'aria-current'?: 'page';
      onClick?: MouseEventHandler<HTMLAnchorElement>;
      children?: ReactNode;
    }>;
    onNavigate?: (href: string) => void;
    onNewChat?: () => void;
  }) => (
    <div>
      <div data-testid="conversation-list-slot">{conversationList}</div>
      <div data-testid="active-path">{activePath}</div>
      <div data-testid="sidebar-open">{String(sidebarOpen)}</div>
      <div data-testid="overlay-sidebar-open">{String(overlaySidebarOpen)}</div>
      <div data-testid="mobile-home-mode">{String(mobileHomeMode)}</div>
      <div data-testid="hide-mobile-tabbar">{String(hideMobileTabBar)}</div>
      <button type="button" data-testid="new-chat" onClick={onNewChat}>new-chat</button>
      {navItems.map((item) => (
        <div key={item.href} data-testid={`nav-${item.href}`}>
          {LinkComponent ? (
            <LinkComponent
              href={item.href}
              prefetch
              title={item.label}
              onClick={() => onNavigate?.(item.href)}
            >
              <span data-testid={`nav-link-label-${item.href}`}>{item.label}</span>
            </LinkComponent>
          ) : (
            item.label
          )}
        </div>
      ))}
      {notesEntry && (
        <div data-testid={`notes-entry-${notesEntry.href}`}>
          {LinkComponent ? (
            <LinkComponent
              href={notesEntry.href}
              prefetch
              title={notesEntry.label}
              onClick={() => onNavigate?.(notesEntry.href)}
            >
              <span data-testid={`notes-link-label-${notesEntry.href}`}>{notesEntry.label}</span>
            </LinkComponent>
          ) : (
            notesEntry.label
          )}
        </div>
      )}
      <div data-testid="app-shell-children">{children}</div>
    </div>
  ),
}));

vi.mock('../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: any) => unknown) => selector({
    sidebarOpen: true,
    setSidebarOpen: vi.fn(),
    catalogSkills: [],
    userSkills: [],
    syncBanner: null,
    remotelyDeletedConvID: null,
    activeConversationId: null,
    clearRemotelyDeletedConvID: vi.fn(),
    setActiveConversationId: vi.fn(),
  }),
  getVanillaStore: () => ({
    getState: () => ({
      setActiveConversationId: vi.fn(),
      setLastUsedModelRef: vi.fn(),
    }),
  }),
}));

vi.mock('../lib/hooks/useMediaQuery', () => ({
  useMediaQuery: (query: string) => {
    if (query === '(max-width: 767px)') return mocks.isMobile;
    if (query === '(max-width: 1023px)') return mocks.isOverlayViewport;
    return false;
  },
}));

vi.mock('./sidebar/ConversationList', () => ({
  ConversationList: () => <div data-testid="conversation-list" />,
}));

vi.mock('./Toast', () => ({
  ToastContainer: () => <div data-testid="toast-container" />,
  showToast: vi.fn(),
}));

describe('AppShellWrapper', () => {
  beforeEach(() => {
    mocks.pathname = '/chat';
    mocks.searchParams = new URLSearchParams();
    mocks.isMobile = false;
    mocks.isOverlayViewport = false;
    mocks.push.mockClear();
    mocks.lastLinkDefaultPrevented = undefined;
  });

  it('renders the app shell with sidebar slots and children', () => {
    render(
      <AppShellWrapper>
        <div>Inner Content</div>
      </AppShellWrapper>,
    );

    expect(screen.getByTestId('conversation-list')).toBeTruthy();
    expect(screen.queryByTestId('skills-pills')).toBeNull();
    expect(screen.getByText('Inner Content')).toBeTruthy();
    expect(screen.getByTestId('toast-container')).toBeTruthy();
  });

  it('uses chat as the home dock target and active path', () => {
    render(
      <AppShellWrapper>
        <div>Inner Content</div>
      </AppShellWrapper>,
    );

    expect(screen.getByTestId('nav-/chat').textContent).toBe('home');
    expect(screen.getByTestId('active-path').textContent).toBe('/chat');
  });

  it('keeps notes out of the dock and exposes it as the sidebar entry', () => {
    render(
      <AppShellWrapper>
        <div>Inner Content</div>
      </AppShellWrapper>,
    );

    //   dock 3  
    expect(screen.queryByTestId('nav-/notes')).toBeNull();
    expect(screen.getByTestId('notes-entry-/notes').textContent).toBe('notes');
  });

  it('keeps the home dock item selected on chat detail routes', () => {
    mocks.pathname = '/chat/conversation-1';

    render(
      <AppShellWrapper>
        <div>Inner Content</div>
      </AppShellWrapper>,
    );

    expect(screen.getByTestId('active-path').textContent).toBe('/chat');
  });

  it('treats mobile chat root as the Home surface without opening the overlay drawer', () => {
    mocks.isMobile = true;
    mocks.isOverlayViewport = true;
    mocks.pathname = '/chat';

    render(
      <AppShellWrapper>
        <div>Inner Content</div>
      </AppShellWrapper>,
    );

    expect(screen.getByTestId('mobile-home-mode').textContent).toBe('true');
    expect(screen.getByTestId('hide-mobile-tabbar').textContent).toBe('false');
    expect(screen.getByTestId('overlay-sidebar-open').textContent).toBe('false');
  });

  it('keeps the overlay drawer closed before mobile media query hydration resolves', () => {
    mocks.isMobile = false;
    mocks.pathname = '/chat';

    const { rerender } = render(
      <AppShellWrapper>
        <div>Inner Content</div>
      </AppShellWrapper>,
    );

    expect(screen.getByTestId('sidebar-open').textContent).toBe('true');
    expect(screen.getByTestId('overlay-sidebar-open').textContent).toBe('false');

    mocks.searchParams = new URLSearchParams('compose=1');
    rerender(
      <AppShellWrapper>
        <div>Inner Content</div>
      </AppShellWrapper>,
    );

    expect(screen.getByTestId('sidebar-open').textContent).toBe('true');
    expect(screen.getByTestId('overlay-sidebar-open').textContent).toBe('false');
  });

  it('treats mobile compose and conversation routes as full-screen chat surfaces', () => {
    mocks.isMobile = true;
    mocks.isOverlayViewport = true;
    mocks.pathname = '/chat';
    mocks.searchParams = new URLSearchParams('compose=1');

    const { rerender } = render(
      <AppShellWrapper>
        <div>Inner Content</div>
      </AppShellWrapper>,
    );

    expect(screen.getByTestId('mobile-home-mode').textContent).toBe('false');
    expect(screen.getByTestId('hide-mobile-tabbar').textContent).toBe('true');

    mocks.pathname = '/chat/conversation-1';
    mocks.searchParams = new URLSearchParams();
    rerender(
      <AppShellWrapper>
        <div>Inner Content</div>
      </AppShellWrapper>,
    );

    expect(screen.getByTestId('mobile-home-mode').textContent).toBe('false');
    expect(screen.getByTestId('hide-mobile-tabbar').textContent).toBe('true');
  });

  it('keeps tablet overlay drawer behavior tied to the sidebar state', () => {
    mocks.isMobile = false;
    mocks.isOverlayViewport = true;
    mocks.pathname = '/chat/conversation-1';

    render(
      <AppShellWrapper>
        <div>Inner Content</div>
      </AppShellWrapper>,
    );

    expect(screen.getByTestId('sidebar-open').textContent).toBe('true');
    expect(screen.getByTestId('overlay-sidebar-open').textContent).toBe('true');
  });

  it('keeps provider and settings dock items selected on nested routes', () => {
    mocks.pathname = '/providers/provider-1';

    const { rerender } = render(
      <AppShellWrapper>
        <div>Inner Content</div>
      </AppShellWrapper>,
    );

    expect(screen.getByTestId('active-path').textContent).toBe('/providers');

    mocks.pathname = '/settings/memory';
    rerender(
      <AppShellWrapper>
        <div>Inner Content</div>
      </AppShellWrapper>,
    );

    expect(screen.getByTestId('active-path').textContent).toBe('/settings');
  });

  it('keeps the settings dock item selected on the skills route', () => {
    mocks.pathname = '/skills';

    render(
      <AppShellWrapper>
        <div>Inner Content</div>
      </AppShellWrapper>,
    );

    expect(screen.getByTestId('active-path').textContent).toBe('/settings');
  });

  it('does not cancel desktop app nav link clicks so Next can perform same-document navigation', () => {
    render(
      <AppShellWrapper>
        <div>Inner Content</div>
      </AppShellWrapper>,
    );

    const link = screen.getByTestId('nav-link-label-/providers').closest('a');
    expect(link).toBeTruthy();

    fireEvent.click(link!, { button: 0 });

    expect(mocks.lastLinkDefaultPrevented).toBe(false);
  });

  it('uses router.push for desktop new-chat instead of reloading the document', () => {
    render(
      <AppShellWrapper>
        <div>Inner Content</div>
      </AppShellWrapper>,
    );

    fireEvent.click(screen.getByTestId('new-chat'));

    expect(mocks.push).toHaveBeenCalledWith('/chat');
  });
});

describe('resolveDesktopNavigationURL', () => {
  it('normalizes extensionless app routes to trailing-slash app:// URLs', () => {
    expect(resolveDesktopNavigationURL('/notes', 'app://app')).toBe('app://app/notes/');
    expect(resolveDesktopNavigationURL('/providers', 'app://app')).toBe('app://app/providers/');
  });

  it('preserves query params while normalizing app routes', () => {
    expect(resolveDesktopNavigationURL('/chat?compose=1', 'app://app')).toBe('app://app/chat/?compose=1');
  });
});
