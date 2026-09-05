'use client';

import { useEffect, useState, type ReactNode } from 'react';
import { useParams, usePathname, useSearchParams } from 'next/navigation';
import { useAppStore } from '../../providers/StoreProvider';
import {
  clearNewConversationRoutePromotion,
  isNewConversationRoutePromotion,
} from '../../lib/core/chat/route-transition';
import { MobileHomeView } from '../mobile/MobileHomeView';
import { ChatView } from './ChatView';
import styles from './ChatRouteShell.module.css';

interface ChatRouteShellProps {
  children: ReactNode;
}

function readConversationId(value: string | string[] | undefined): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined;
}

type ChatRouteIdentity =
  | { kind: 'other' }
  | { kind: 'new' }
  | { kind: 'conversation'; conversationId: string };

interface ChatSurfaceState {
  identity: ChatRouteIdentity;
  generation: number;
}

function sameRouteIdentity(left: ChatRouteIdentity, right: ChatRouteIdentity): boolean {
  if (left.kind !== right.kind) return false;
  if (left.kind !== 'conversation' || right.kind !== 'conversation') return true;
  return left.conversationId === right.conversationId;
}

/**
 * Keeps the chat surface mounted while the leaf route changes from /chat to /chat/:id.
 * The leaf pages are URL boundaries only; conversation state belongs to this shared layout.
 */
export function ChatRouteShell({ children }: ChatRouteShellProps) {
  const pathname = usePathname() ?? '';
  const params = useParams<{ conversationId?: string | string[] }>();
  const searchParams = useSearchParams();
  const setActiveConversationId = useAppStore((state) => state.setActiveConversationId);

  const isNewChatRoute = pathname === '/chat';
  const conversationId = readConversationId(params.conversationId);
  const isConversationRoute = Boolean(conversationId && /^\/chat\/[^/]+\/?$/.test(pathname));
  const isChatSurfaceRoute = isNewChatRoute || isConversationRoute;
  const showMobileHome = isNewChatRoute && searchParams.get('compose') !== '1';
  const routeIdentity: ChatRouteIdentity = isNewChatRoute
    ? { kind: 'new' }
    : isConversationRoute && conversationId
      ? { kind: 'conversation', conversationId }
      : { kind: 'other' };
  const [surfaceState, setSurfaceState] = useState<ChatSurfaceState>(() => ({
    identity: routeIdentity,
    generation: 0,
  }));

  if (!sameRouteIdentity(surfaceState.identity, routeIdentity)) {
    const preservesNewConversation =
      surfaceState.identity.kind === 'new' &&
      routeIdentity.kind === 'conversation' &&
      isNewConversationRoutePromotion(routeIdentity.conversationId);
    setSurfaceState({
      identity: routeIdentity,
      generation: preservesNewConversation
        ? surfaceState.generation
        : surfaceState.generation + 1,
    });
  }

  useEffect(() => {
    setActiveConversationId(isConversationRoute ? conversationId ?? null : null);
  }, [conversationId, isConversationRoute, setActiveConversationId]);

  useEffect(() => () => {
    setActiveConversationId(null);
  }, [setActiveConversationId]);

  useEffect(() => {
    if (routeIdentity.kind === 'conversation') {
      clearNewConversationRoutePromotion(routeIdentity.conversationId);
    }
  }, [routeIdentity.kind, conversationId]);

  if (!isChatSurfaceRoute) return children;

  return (
    <>
      {showMobileHome ? (
        <div key="mobile-home" className={styles.mobileSurface}>
          <MobileHomeView />
        </div>
      ) : null}
      <div
        key="chat-surface"
        className={showMobileHome ? styles.desktopSurface : styles.chatSurface}
      >
        <ChatView
          key={`chat-surface-${surfaceState.generation}`}
          conversationId={isConversationRoute ? conversationId : undefined}
          searchQuery={isConversationRoute ? searchParams.get('q')?.trim() || undefined : undefined}
        />
      </div>
    </>
  );
}
