'use client';

import {
  type ReactNode,
  type ComponentType,
  type CSSProperties,
  type KeyboardEvent,
  type MouseEvent,
  type PointerEvent,
  useState,
  useCallback,
} from 'react';
import { OriveoLogo } from '../OriveoLogo/OriveoLogo';
import styles from './AppShell.module.css';

export const MIN_SIDEBAR_WIDTH = 220;
export const MAX_SIDEBAR_WIDTH = 520;
export const DEFAULT_SIDEBAR_WIDTH = 300;
const KEYBOARD_STEP = 16;

function clampWidth(px: number): number {
  if (Number.isNaN(px)) return DEFAULT_SIDEBAR_WIDTH;
  return Math.round(Math.max(MIN_SIDEBAR_WIDTH, Math.min(MAX_SIDEBAR_WIDTH, px)));
}

interface NavItem {
  label: string;
  href: string;
  icon?: ReactNode;
}

/**
 * Link component contract, compatible with the Next.js <Link>. packages/ui is a plain React
 * library, so the next/link implementation is injected from above to get prefetch, which warms
 * the RSC payload on hover.
 */
export interface AppShellLinkProps {
  href: string;
  prefetch?: boolean;
  className?: string;
  title?: string;
  'aria-current'?: 'page';
  onClick?: (e: MouseEvent<HTMLAnchorElement>) => void;
  children?: ReactNode;
}

interface AppShellProps {
  children: ReactNode;
  navItems?: NavItem[];
  activePath?: string;
  conversationList?: ReactNode;
  onNewChat?: () => void;
  /** Secondary entry below "New chat", such as Notes. Rendered through LinkComponent so it gets prefetch and the active state. */
  notesEntry?: NavItem;
  /** Controlled sidebar state. Falls back to internal state if omitted. */
  sidebarOpen?: boolean;
  /** Mobile/tablet drawer state. Defaults to sidebarOpen for backward compatibility. */
  overlaySidebarOpen?: boolean;
  /** Marks the chat root as a native-style mobile Home surface instead of a drawer-backed chat. */
  mobileHomeMode?: boolean;
  /** Hide the mobile bottom tab bar on full-screen child surfaces such as active chats. */
  hideMobileTabBar?: boolean;
  onToggleSidebar?: () => void;
  onCloseOverlaySidebar?: () => void;
  /**
   * Link component injected from above (next/link). When present, nav items render as
   * <Link prefetch>, so hovering warms the RSC payload and the click switches instantly.
   * onNavigate is still honoured for side effects such as closing the mobile drawer.
   */
  LinkComponent?: ComponentType<AppShellLinkProps>;
  /** SPA navigation callback. Falls back to onClick when LinkComponent is absent. */
  onNavigate?: (href: string) => void;
  /** Label for the New Chat button */
  newChatLabel?: string;
  /** Status card above the bottom nav, such as the free-tier quota card. */
  bottomCard?: ReactNode;
  /**
   * Controlled sidebar width in px. Only applies on desktop at 1024px and up; tablet and mobile
   * use an overlay drawer. When omitted, the CSS variable `--o-sidebar-width` supplies the default.
   */
  sidebarWidth?: number;
  /**
   * Final callback when the user resizes by drag, double click or keyboard, already clamped to
   * [MIN, MAX]. It does not fire during the drag, only once on commit, so the host can persist it.
   */
  onSidebarWidthChange?: (width: number) => void;
  /** aria-label for the drag handle; the localised copy is injected from above. */
  resizerLabel?: string;
}

export function AppShell({
  children,
  navItems,
  activePath,
  conversationList,
  onNewChat,
  notesEntry,
  sidebarOpen: controlledOpen,
  overlaySidebarOpen,
  mobileHomeMode,
  hideMobileTabBar,
  onToggleSidebar,
  onCloseOverlaySidebar,
  LinkComponent,
  onNavigate,
  newChatLabel,
  bottomCard,
  sidebarWidth,
  onSidebarWidthChange,
  resizerLabel,
}: AppShellProps) {
  const [internalOpen, setInternalOpen] = useState(true);

  const isControlled = controlledOpen !== undefined;
  const sidebarOpen = isControlled ? controlledOpen : internalOpen;
  const isOverlaySidebarOpen = overlaySidebarOpen ?? sidebarOpen;

  /**
   * Temporary width used while dragging.
   * - during a drag: draftWidth updates every frame and this component re-renders itself
   * - on pointerup: onSidebarWidthChange fires once with the final value and the draft is cleared
   * That keeps the drag visually responsive without a store or localStorage write per pixel.
   */
  const [draftWidth, setDraftWidth] = useState<number | null>(null);
  const [isResizing, setIsResizing] = useState(false);

  const effectiveWidth = draftWidth ?? sidebarWidth;
  const widthVarStyle: CSSProperties | undefined =
    effectiveWidth !== undefined
      ? ({ ['--o-sidebar-width-user' as string]: `${effectiveWidth}px` } as CSSProperties)
      : undefined;

  const toggleSidebar = useCallback(() => {
    if (onToggleSidebar) {
      onToggleSidebar();
    } else {
      setInternalOpen((prev) => !prev);
    }
  }, [onToggleSidebar]);

  const closeMobileDrawer = useCallback(() => {
    if (onCloseOverlaySidebar) {
      onCloseOverlaySidebar();
    } else if (onToggleSidebar) {
      onToggleSidebar();
    } else {
      setInternalOpen(false);
    }
  }, [onCloseOverlaySidebar, onToggleSidebar]);

  const handleResizerPointerDown = useCallback(
    (e: PointerEvent<HTMLDivElement>) => {
      if (!onSidebarWidthChange) return;
      // Only respond to the primary button, touch or pen
      if (e.button !== 0 && e.pointerType === 'mouse') return;
      e.preventDefault();
      const startX = e.clientX;
      const startWidth = sidebarWidth ?? DEFAULT_SIDEBAR_WIDTH;
      setIsResizing(true);

      // Tell a real drag from a click or double click: only movement over 1px counts as a drag
      // and commits. Otherwise a double click fires two pointerdown/up rounds and writes an
      // unintended commit.
      let hasMoved = false;
      const computeNext = (clientX: number) => clampWidth(startWidth + (clientX - startX));

      // Listen on window so move/up still arrive when the pointer leaves the resizer or the
      // viewport; more reliable than setPointerCapture, whose behaviour differs noticeably
      // between browsers and jsdom.
      const handleMove = (ev: globalThis.PointerEvent) => {
        if (!hasMoved && Math.abs(ev.clientX - startX) > 1) hasMoved = true;
        if (hasMoved) setDraftWidth(computeNext(ev.clientX));
      };
      const handleUp = (ev: globalThis.PointerEvent) => {
        cleanup();
        setIsResizing(false);
        setDraftWidth(null);
        if (hasMoved) onSidebarWidthChange(computeNext(ev.clientX));
      };
      const handleCancel = () => {
        cleanup();
        setIsResizing(false);
        setDraftWidth(null);
      };
      const cleanup = () => {
        window.removeEventListener('pointermove', handleMove);
        window.removeEventListener('pointerup', handleUp);
        window.removeEventListener('pointercancel', handleCancel);
      };

      window.addEventListener('pointermove', handleMove);
      window.addEventListener('pointerup', handleUp);
      window.addEventListener('pointercancel', handleCancel);
    },
    [onSidebarWidthChange, sidebarWidth],
  );

  const handleResizerDoubleClick = useCallback(() => {
    onSidebarWidthChange?.(DEFAULT_SIDEBAR_WIDTH);
  }, [onSidebarWidthChange]);

  const handleResizerKeyDown = useCallback(
    (e: KeyboardEvent<HTMLDivElement>) => {
      if (!onSidebarWidthChange) return;
      const current = sidebarWidth ?? DEFAULT_SIDEBAR_WIDTH;
      let next: number | null = null;
      // RTL is not handled: this is an LTR layout, and under RTL the arrow keys would follow visual left/right rather than logical order
      if (e.key === 'ArrowLeft') next = current - KEYBOARD_STEP;
      else if (e.key === 'ArrowRight') next = current + KEYBOARD_STEP;
      else if (e.key === 'Home') next = MIN_SIDEBAR_WIDTH;
      else if (e.key === 'End') next = MAX_SIDEBAR_WIDTH;
      else if (e.key === 'Enter' || e.key === ' ') next = DEFAULT_SIDEBAR_WIDTH;
      if (next === null) return;
      e.preventDefault();
      onSidebarWidthChange(clampWidth(next));
    },
    [onSidebarWidthChange, sidebarWidth],
  );

  const ariaWidth = effectiveWidth ?? DEFAULT_SIDEBAR_WIDTH;

  const renderNavItem = (item: NavItem, className: string, activeClassName?: string) => {
    const isActive = activePath === item.href;
    const itemClassName = `${className} ${isActive && activeClassName ? activeClassName : ''}`;

    if (LinkComponent) {
      return (
        <LinkComponent
          key={item.href}
          href={item.href}
          prefetch
          className={itemClassName}
          aria-current={isActive ? 'page' : undefined}
          title={item.label}
          onClick={() => {
            onNavigate?.(item.href);
          }}
        >
          {item.icon}
          <span>{item.label}</span>
        </LinkComponent>
      );
    }

    if (onNavigate) {
      return (
        <button
          key={item.href}
          type="button"
          className={itemClassName}
          aria-current={isActive ? 'page' : undefined}
          onClick={() => onNavigate(item.href)}
          title={item.label}
        >
          {item.icon}
          <span>{item.label}</span>
        </button>
      );
    }

    return (
      <a
        key={item.href}
        href={item.href}
        className={itemClassName}
        aria-current={isActive ? 'page' : undefined}
        title={item.label}
      >
        {item.icon}
        <span>{item.label}</span>
      </a>
    );
  };

  return (
    <div
      className={styles.shell}
      data-sidebar-open={sidebarOpen}
      data-overlay-sidebar-open={isOverlaySidebarOpen}
      data-mobile-home={mobileHomeMode || undefined}
      data-mobile-tabbar-hidden={hideMobileTabBar || undefined}
      data-resizing={isResizing || undefined}
      style={widthVarStyle}
    >
      {/* Mobile overlay */}
      {isOverlaySidebarOpen && (
        <div className={styles.overlay} onClick={closeMobileDrawer} />
      )}

      <aside className={styles.sidebar} role="complementary" aria-label="Sidebar">
        {/* Header */}
        <div className={styles.sidebarHeader}>
          <div className={styles.brand}>
            <OriveoLogo size={24} className={styles.brandIcon} />
            <span className={styles.brandName}>Oriveo</span>
          </div>
          <button
            className={styles.toggleBtn}
            onClick={toggleSidebar}
            aria-label="Toggle sidebar"
          >
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <line x1="3" y1="6" x2="21" y2="6" />
              <line x1="3" y1="12" x2="21" y2="12" />
              <line x1="3" y1="18" x2="21" y2="18" />
            </svg>
          </button>
        </div>

        {/* New Chat plus the secondary entry (Notes) */}
        <div className={styles.sidebarActions}>
          <button className={styles.newChatBtn} onClick={onNewChat}>
            {/* Inline path for the lucide MessageSquarePlus glyph, so @oriveo/ui keeps zero dependencies and does not pull in lucide-react */}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round">
              <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
              <path d="M12 7v6" />
              <path d="M9 10h6" />
            </svg>
            {newChatLabel ?? 'New Chat'}
          </button>
          {notesEntry && renderNavItem(notesEntry, styles.notesEntryBtn, styles.notesEntryBtnActive)}
        </div>

        {/* Conversation list */}
        <div className={styles.conversationList}>
          {conversationList}
        </div>

        {/* Bottom card (e.g. Free status) */}
        {bottomCard && (
          <div className={styles.sidebarBottomCard}>{bottomCard}</div>
        )}

        {/* Bottom nav */}
        <nav className={styles.sidebarNav} aria-label="Main navigation">
          {navItems?.map((item) => renderNavItem(item, styles.navItem, styles.navItemActive))}
        </nav>
      </aside>

      {/* The resizer sits outside the sidebar and before main: the sidebar has overflow:hidden,
          so only from out here can the hit area straddle the edge without being clipped. */}
      {sidebarOpen && onSidebarWidthChange && (
        <div
          className={styles.resizer}
          role="separator"
          aria-orientation="vertical"
          aria-label={resizerLabel ?? 'Resize sidebar'}
          aria-valuenow={ariaWidth}
          aria-valuemin={MIN_SIDEBAR_WIDTH}
          aria-valuemax={MAX_SIDEBAR_WIDTH}
          tabIndex={0}
          data-active={isResizing || undefined}
          onPointerDown={handleResizerPointerDown}
          onDoubleClick={handleResizerDoubleClick}
          onKeyDown={handleResizerKeyDown}
        />
      )}

      <main className={styles.content} id="main-content" tabIndex={-1}>
        {!sidebarOpen && (
          <button
            className={styles.sidebarOpenBtn}
            onClick={toggleSidebar}
            aria-label="Open sidebar"
          >
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <line x1="3" y1="6" x2="21" y2="6" />
              <line x1="3" y1="12" x2="21" y2="12" />
              <line x1="3" y1="18" x2="21" y2="18" />
            </svg>
          </button>
        )}
        {children}
      </main>

      {navItems && navItems.length > 0 && !hideMobileTabBar && (
        <nav className={styles.mobileTabBar} aria-label="Main navigation">
          {navItems.map((item) => renderNavItem(item, styles.mobileTabItem))}
        </nav>
      )}
    </div>
  );
}
