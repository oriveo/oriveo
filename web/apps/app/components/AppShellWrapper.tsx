'use client';

import { type MouseEvent, type ReactNode, useMemo, useCallback, useEffect, useState } from 'react';
import { useRouter, usePathname, useSearchParams } from 'next/navigation';
import NextLink from 'next/link';
import { useTranslations } from 'next-intl';
import { NotebookPen } from 'lucide-react';
import { AppShell, type AppShellLinkProps } from '@oriveo/ui';
import { HomeTabIcon, ProvidersTabIcon, SettingsTabIcon } from './TabBarIcons';
import { useAppStore } from '../providers/StoreProvider';
import { useMediaQuery } from '../lib/hooks/useMediaQuery';
import { ConversationList } from './sidebar/ConversationList';
import { ServiceReachabilityBanner } from './ServiceReachabilityBanner';
import { StoragePersistenceBanner } from './StoragePersistenceBanner';
import { ToastContainer } from './Toast';

const SIDEBAR_WIDTH_KEY = 'oriveo:sidebarWidth';
const SIDEBAR_WIDTH_MIN = 220;
const SIDEBAR_WIDTH_MAX = 520;
const DESKTOP_NAVIGATION_FALLBACK_MS = 1200;
let pendingDesktopNavigationFallback: ReturnType<typeof setTimeout> | undefined;

function readPersistedWidth(): number | undefined {
  if (typeof window === 'undefined') return undefined;
  try {
    const raw = window.localStorage.getItem(SIDEBAR_WIDTH_KEY);
    if (!raw) return undefined;
    const parsed = Number.parseInt(raw, 10);
    if (!Number.isFinite(parsed)) return undefined;
    if (parsed < SIDEBAR_WIDTH_MIN || parsed > SIDEBAR_WIDTH_MAX) return undefined;
    return parsed;
  } catch {
    return undefined;
  }
}

interface AppShellWrapperProps {
  children: ReactNode;
}

function isExtensionlessRoute(pathname: string): boolean {
  return !/\.[a-z0-9]+$/i.test(pathname);
}

export function resolveDesktopNavigationURL(href: string, origin: string): string {
  const url = new URL(href, origin);
  if (url.protocol === 'app:' && isExtensionlessRoute(url.pathname) && !url.pathname.endsWith('/')) {
    url.pathname = `${url.pathname}/`;
  }
  return url.toString();
}

function isDesktopAppRuntime(): boolean {
  return typeof window !== 'undefined' && window.location.protocol === 'app:';
}

function isPlainPrimaryClick(event: MouseEvent<HTMLAnchorElement>): boolean {
  return (
    event.button === 0 &&
    !event.metaKey &&
    !event.ctrlKey &&
    !event.shiftKey &&
    !event.altKey
  );
}

function getDesktopNavigationOrigin(): string | null {
  if (typeof window === 'undefined') return null;
  if (window.location.origin && window.location.origin !== 'null') return window.location.origin;
  if (window.location.protocol && window.location.host) {
    const origin = `${window.location.protocol}//${window.location.host}`;
    return origin === 'null://' ? null : origin;
  }
  return null;
}

function normalizePathname(pathname: string): string {
  if (pathname === '/') return pathname;
  return pathname.replace(/\/+$/, '');
}

function desktopLocationMatches(href: string): boolean {
  const origin = getDesktopNavigationOrigin();
  if (!origin) return true;
  try {
    const target = new URL(href, origin);
    return (
      normalizePathname(window.location.pathname) === normalizePathname(target.pathname) &&
      window.location.search === target.search
    );
  } catch {
    return true;
  }
}

function navigateDesktopFallback(href: string): void {
  const origin = getDesktopNavigationOrigin();
  if (!origin) return;
  window.location.assign(resolveDesktopNavigationURL(href, origin));
}

function scheduleDesktopNavigationFallback(href: string): void {
  if (!isDesktopAppRuntime() || desktopLocationMatches(href)) return;
  if (pendingDesktopNavigationFallback) clearTimeout(pendingDesktopNavigationFallback);
  pendingDesktopNavigationFallback = setTimeout(() => {
    pendingDesktopNavigationFallback = undefined;
    if (!desktopLocationMatches(href)) navigateDesktopFallback(href);
  }, DESKTOP_NAVIGATION_FALLBACK_MS);
}

// Inject next/link into the AppShell from @oriveo/ui to enable hover prefetch
function NavLink({
  href,
  prefetch,
  className,
  title,
  onClick,
  children,
  'aria-current': ariaCurrent,
}: AppShellLinkProps) {
  const handleClick = (event: MouseEvent<HTMLAnchorElement>) => {
    onClick?.(event);
    if (event.defaultPrevented || !isPlainPrimaryClick(event)) return;
    scheduleDesktopNavigationFallback(href);
  };

  return (
    <NextLink
      href={href}
      prefetch={prefetch}
      className={className}
      title={title}
      aria-current={ariaCurrent}
      onClick={handleClick}
    >
      {children}
    </NextLink>
  );
}

export function AppShellWrapper({ children }: AppShellWrapperProps) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const activeNavPath = useMemo(() => {
    if (pathname === '/' || pathname.startsWith('/chat')) return '/chat';
    if (pathname.startsWith('/providers')) return '/providers';
    if (pathname.startsWith('/notes')) return '/notes';
    if (pathname.startsWith('/settings') || pathname.startsWith('/skills')) return '/settings';
    return pathname;
  }, [pathname]);
  const firstChatSegment = pathname.startsWith('/chat/')
    ? pathname.split('/')[2]
    : undefined;
  const isConversationChatRoute = Boolean(
    firstChatSegment &&
    firstChatSegment !== 'usage' &&
    firstChatSegment !== 'folder',
  );
  const isComposeChatRoute = pathname === '/chat' && searchParams.get('compose') === '1';
  const isMobileHomeRoute = pathname === '/chat' && !isComposeChatRoute;
  const isMobileFullscreenChat = isComposeChatRoute || isConversationChatRoute;
  const t = useTranslations('nav');
  const tSidebar = useTranslations('sidebar');

  const sidebarOpen = useAppStore((s) => s.sidebarOpen);
  const setSidebarOpen = useAppStore((s) => s.setSidebarOpen);

  const isMobile = useMediaQuery('(max-width: 767px)');
  const isOverlayViewport = useMediaQuery('(max-width: 1023px)');
  const [mobileSidebarReady, setMobileSidebarReady] = useState(false);

  // SSR safe: the first paint carries no width (the CSS variable falls back to the default 300), and localStorage is read and injected after the client mounts
  const [sidebarWidth, setSidebarWidthState] = useState<number | undefined>(undefined);
  useEffect(() => {
    setSidebarWidthState(readPersistedWidth());
  }, []);

  useEffect(() => {
    if (!isMobile) {
      setMobileSidebarReady(false);
      return;
    }
    setSidebarOpen(false);
    setMobileSidebarReady(true);
  }, [isMobile, setSidebarOpen]);
  const handleSidebarWidthChange = useCallback((width: number) => {
    setSidebarWidthState(width);
    try {
      window.localStorage.setItem(SIDEBAR_WIDTH_KEY, String(width));
    } catch {
      // Private mode or a full quota: discard silently and fall back to the default on next launch
    }
  }, []);

  // Status banner, plus the route change for a conversation a synchronisation backend reports as deleted elsewhere.
  const syncBanner = useAppStore((s) => s.syncBanner);
  const remotelyDeletedConvID = useAppStore((s) => s.remotelyDeletedConvID);
  const activeConversationId = useAppStore((s) => s.activeConversationId);
  const clearRemotelyDeletedConvID = useAppStore((s) => s.clearRemotelyDeletedConvID);
  const setActiveConversationId = useAppStore((s) => s.setActiveConversationId);

  useEffect(() => {
    if (!remotelyDeletedConvID) return;
    if (remotelyDeletedConvID === activeConversationId) {
      router.push('/chat');
    }
    clearRemotelyDeletedConvID();
  }, [remotelyDeletedConvID, activeConversationId, router, clearRemotelyDeletedConvID]);

  const navItems = useMemo(
    () => [
  // Hand-drawn icons; the per-tab selected color is applied by CSS keyed on href (see AppShell.module.css)
  // Notes stay out of the dock (a fourth item in a three-column grid wraps and misaligns) and live below "new conversation" in the sidebar instead (notesEntry).
      { label: t('home'), href: '/chat', icon: <HomeTabIcon /> },
      { label: t('providers'), href: '/providers', icon: <ProvidersTabIcon /> },
      { label: t('settings'), href: '/settings', icon: <SettingsTabIcon /> },
    ],
    [t],
  );

  const notesEntry = useMemo(
    () => ({ label: t('notes'), href: '/notes', icon: <NotebookPen strokeWidth={1.75} /> }),
    [t],
  );

  const handleNewChat = useCallback(() => {
    setActiveConversationId(null);
    const target = isMobile ? '/chat?compose=1' : '/chat';
    if (isMobile) {
      setSidebarOpen(false);
    }
    router.push(target);
    scheduleDesktopNavigationFallback(target);
  }, [isMobile, router, setActiveConversationId, setSidebarOpen]);

  const handleToggleSidebar = useCallback(() => {
    setSidebarOpen(!sidebarOpen);
  }, [sidebarOpen, setSidebarOpen]);

  // LinkComponent takes over routing; onNavigate only handles side effects such as the mobile drawer
  const handleNavigate = useCallback(
    (_href: string) => {
      if (isMobile) setSidebarOpen(false);
    },
    [isMobile, setSidebarOpen],
  );

  const overlaySidebarOpen = isMobile
    ? mobileSidebarReady && isMobileFullscreenChat && sidebarOpen
    : isOverlayViewport && sidebarOpen;

  return (
    <AppShell
      navItems={navItems}
      notesEntry={notesEntry}
      activePath={activeNavPath}
      conversationList={<ConversationList />}
      onNewChat={handleNewChat}
      sidebarOpen={sidebarOpen}
      overlaySidebarOpen={overlaySidebarOpen}
      mobileHomeMode={isMobileHomeRoute}
      hideMobileTabBar={isMobileFullscreenChat}
      onToggleSidebar={handleToggleSidebar}
      onCloseOverlaySidebar={() => setSidebarOpen(false)}
      LinkComponent={NavLink}
      onNavigate={handleNavigate}
      newChatLabel={tSidebar('newChat')}
      bottomCard={null}
      sidebarWidth={sidebarWidth}
      onSidebarWidthChange={handleSidebarWidthChange}
      resizerLabel={tSidebar('resizeSidebar')}
    >
      {syncBanner && (
        <div style={{
          position: 'fixed', top: 12, left: '50%', transform: 'translateX(-50%)',
          zIndex: 9999, padding: '8px 16px', borderRadius: 8,
          background: 'var(--o-surface-chrome, #333)', color: 'var(--o-primary-text, #fff)',
          fontSize: 13, boxShadow: '0 2px 8px rgba(0,0,0,0.2)',
        }}>
          {syncBanner}
        </div>
      )}
      {children}
      <ToastContainer />
      <ServiceReachabilityBanner />
      <StoragePersistenceBanner />
    </AppShell>
  );
}
