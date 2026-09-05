'use client';

import { useEffect } from 'react';
import { warmConversationAnchorInStore } from '../core/chat/conversation-bootstrap';
import { normalizeUUID } from '../utils/id-utils';

export function useFocusMessage(
  messageId?: string | null,
  options: { conversationId?: string | null } = {},
) {
  const conversationId = options.conversationId;

  useEffect(() => {
    if (!messageId) return;
    const canonicalMessageId = normalizeUUID(messageId);
    const canonicalConversationId = conversationId ? normalizeUUID(conversationId) : conversationId;
    let cancelled = false;
    let attempts = 0;
    let anchorWarmRequested = false;
    let timer: number | undefined;

    const focus = () => {
      if (cancelled) return;
      attempts += 1;
      const escaped = typeof CSS !== 'undefined' && CSS.escape
        ? CSS.escape(canonicalMessageId)
        : canonicalMessageId.replace(/"/g, '\\"');
      const target = document.querySelector<HTMLElement>(`[data-message-id="${escaped}"]`);
      if (!target) {
        if (!anchorWarmRequested && canonicalConversationId) {
          anchorWarmRequested = true;
          void warmConversationAnchorInStore(canonicalConversationId, canonicalMessageId);
        }
        if (attempts < 30) timer = window.setTimeout(focus, 100);
        return;
      }
      target.scrollIntoView({ block: 'start', behavior: 'smooth' });
      target.classList.remove('o-focus-message');
      void target.offsetWidth;
      target.classList.add('o-focus-message');
      timer = window.setTimeout(() => target.classList.remove('o-focus-message'), 2600);
    };

    timer = window.setTimeout(focus, 80);
    return () => {
      cancelled = true;
      if (timer !== undefined) window.clearTimeout(timer);
      document.querySelectorAll('.o-focus-message').forEach((node) => node.classList.remove('o-focus-message'));
    };
  }, [conversationId, messageId]);
}
