'use client';

import { useCallback } from 'react';
import { useRouter } from 'next/navigation';
import type { AIModel, Provider } from '@oriveo/shared';
import { useAppStore } from '../../../providers/StoreProvider';
import { useMediaQuery } from '../../../lib/hooks/useMediaQuery';
import { createProviderSelectionSnapshot } from '../../../lib/core/providers/provider-selection-snapshot';

/**
 * Single entry point for starting a chat from the provider detail page (the hero card start button
 * and the chat button on an added model row).
 *
 * The four detail variants each did their own `setLastUsedModelRef` plus `router.push('/chat')`, and
 * three of them shared the same omissions:
 *  1. activeConversationId was not cleared, so it relied on an effect after /chat mounts and the
 *     first frame flashed the previous conversation's model;
 *  2. `?compose=1` was missing on mobile, and below 768px /chat renders MobileHomeView, which has no
 *     TopBar, so the chat button never reached the new conversation screen;
 *  3. the hero card only accepted `isDefault`, and without one it navigated away without updating the
 *     ref at all, leaving the previous model in the header.
 *
 * Collapsing them into one place keeps the next shared-semantics change from missing an entry point.
 */
export function useProviderChatLauncher(provider: Provider) {
  const router = useRouter();
  const isMobile = useMediaQuery('(max-width: 767px)');
  const setLastUsedModelRef = useAppStore((s) => s.setLastUsedModelRef);
  const setActiveConversationId = useAppStore((s) => s.setActiveConversationId);

  const openChat = useCallback((modelID: string | null) => {
    setActiveConversationId(null);
    if (modelID) {
      setLastUsedModelRef({ providerID: provider.id, modelID });
    }
    router.push(isMobile ? '/chat?compose=1' : '/chat');
  }, [isMobile, provider.id, router, setActiveConversationId, setLastUsedModelRef]);

  /** Added model row: use whichever model was clicked */
  const startChatWithModel = useCallback((model: AIModel) => {
    openChat(model.id);
  }, [openChat]);

  /**
   * Hero card: resolve the provider's authoritative default model (isDefault, then the metadata
   * default, then the first enabled one).
   * Takes no argument, so binding it straight to onClick cannot mistake a MouseEvent for a model id.
   */
  const startChatWithDefaultModel = useCallback(() => {
    openChat(createProviderSelectionSnapshot(provider)?.defaultModel?.id ?? null);
  }, [openChat, provider]);

  return { startChatWithModel, startChatWithDefaultModel };
}
