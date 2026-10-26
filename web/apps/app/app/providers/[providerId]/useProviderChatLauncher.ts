'use client';

import { useCallback, useMemo, useSyncExternalStore } from 'react';
import { useRouter } from 'next/navigation';
import type { AIModel, Provider } from '@oriveo/shared';
import { useAppStore } from '../../../providers/StoreProvider';
import { useMediaQuery } from '../../../lib/hooks/useMediaQuery';
import { sameNormalizedID } from '../../../lib/utils/id-utils';
import { isProviderUsableForNewChat } from '../../../lib/core/chat/active-selection';
import { getCachedMetadataVersion, onVersionChange } from '../../../lib/core/metadata/metadata-client';
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
  const lastUsedModelRef = useAppStore((s) => s.lastUsedModelRef);
  // The catalog (metadata) is not in React state: subscribe to its version so the usable start model is recomputed after the catalog arrives or refreshes.
  const metadataVersion = useSyncExternalStore(onVersionChange, getCachedMetadataVersion, () => 0);

  const openChat = useCallback((modelID: string | null) => {
    setActiveConversationId(null);
    if (modelID) {
      setLastUsedModelRef({ providerID: provider.id, modelID });
    }
    router.push(isMobile ? '/chat?compose=1' : '/chat');
  }, [isMobile, provider.id, router, setActiveConversationId, setLastUsedModelRef]);

  /** Availability of the model row start-chat button: same criterion as the click; the button is disabled when credentials are missing. */
  const canStartChatWithModel = isProviderUsableForNewChat(provider);

  /** Added model row: use whichever model was clicked; without credentials on this connection chat cannot start (same criterion as the hero card). */
  const startChatWithModel = useCallback((model: AIModel) => {
    if (!canStartChatWithModel) return;
    openChat(model.id);
  }, [canStartChatWithModel, openChat]);

  /**
   * Hero card: the new-conversation chain scoped to this connection: last used pointing at this connection >
   * catalog defaultModelId > the first available one; each tier is checked for availability first (not delisted
   * and enabled), and isDefault is not read; relays have no catalog default.
   * The button availability and the click share this single result: when it is null (all delisted / none
   * available) the button is unavailable and a click does not navigate.
   * A connection without credentials (same criterion as the new-conversation chain, isProviderUsableForNewChat)
   * cannot start: the result is null and the button is hidden.
   */
  const startChatModelID = useMemo(() => {
    if (!isProviderUsableForNewChat(provider)) return null;
    const lastUsedHere = lastUsedModelRef && sameNormalizedID(lastUsedModelRef.providerID, provider.id)
      ? lastUsedModelRef.modelID
      : null;
    const snapshot = createProviderSelectionSnapshot(provider, { preferredModelId: lastUsedHere, lastUsedModelRef });
    return snapshot?.defaultModel?.id ?? null;
  }, [lastUsedModelRef, provider, metadataVersion]);

  /**
   * Hero card click: opens the model resolved above. Takes no argument, so binding it straight to onClick
   * cannot mistake a MouseEvent for a model id.
   */
  const startChatWithDefaultModel = useCallback(() => {
    if (!startChatModelID) return;
    openChat(startChatModelID);
  }, [openChat, startChatModelID]);

  return { startChatWithModel, startChatWithDefaultModel, startChatModelID, canStartChatWithModel };
}
