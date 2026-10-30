'use client';

/**
 * Chat shots, dev route only: one user message and one assistant reply rendered with the
 * production MessageBubble. The reply state (activity, citations, facts, error card) comes from the production
 * startSearchReply → applySearchEvent → finishSearchReply chain, persisted through the production
 * externalSearchMessagePatch; nothing here hand-writes a state value.
 * The fixture names services by catalog id; the local records carry their own ids, so the persisted ids are
 * mapped to the matching local record (what serviceId means at runtime).
 */
import { useLayoutEffect, useMemo } from 'react';
import type { ChatMessage, ProviderKind } from '@oriveo/shared';
import type { SearchService } from '@oriveo/core/search/search-turn';
import { MessageBubble } from '../../../components/chat/MessageBubble';
import { SearchServicesOverride } from '../../../components/chat/SearchErrorCard';
import { applyExternalSearchActivity, clearExternalSearchActivity } from '../../../lib/core/chat/external-search-activity';
import { externalSearchMessagePatch } from '../../../lib/core/chat/external-search-turn';
import { getVanillaStore } from '../../../providers/StoreProvider';
import type { WebSearchChatShot } from './webSearch-shots-data';

const FRAME = { maxWidth: 820, margin: '0 auto', padding: '24px 16px' } as const;
const SHOTS_CONVERSATION_ID = 'shots-conversation';

/** Catalog id → the local record that reuses it (preset); unknown ids stay as they are. */
function localServiceId(shot: WebSearchChatShot, catalogId: string): string {
  const view = shot.local.services.find((s) => s.record.kind === 'preset' && s.record.serviceId === catalogId);
  return view?.record.id ?? catalogId;
}

export function webSearchChatMessages(shot: WebSearchChatShot): [ChatMessage, ChatMessage] {
  const common = {
    providerKind: shot.providerKind as ProviderKind,
    providerName: shot.providerName,
    modelName: shot.modelName,
    estimatedCost: 0,
  };
  const user: ChatMessage = { ...common, id: 'shots-user', role: 'user', text: shot.userText, state: 'delivered' };
  if (shot.phase === 'searching' || !shot.finish) {
    return [user, { ...common, id: 'shots-assistant', role: 'assistant', text: '', state: 'generating' }];
  }
  const service: SearchService = { ...shot.service, id: localServiceId(shot, shot.service.id) };
  const patch = externalSearchMessagePatch(shot.finish, service);
  const card = patch.searchErrorCard;
  const assistant: ChatMessage = {
    ...common,
    id: 'shots-assistant',
    role: 'assistant',
    text: shot.answer,
    state: 'delivered',
    ...patch,
    ...(card
      ? { searchErrorCard: { ...card, switchTo: card.switchTo ? { ...card.switchTo, id: localServiceId(shot, card.switchTo.id) } : null } }
      : {}),
  };
  return [user, assistant];
}

export function WebSearchChatHost({ shot }: { shot: WebSearchChatShot }) {
  const [user, assistant] = useMemo(() => webSearchChatMessages(shot), [shot]);
  const local = useMemo(() => ({ services: shot.local.services, catalog: shot.local.catalog }), [shot]);
  const searching = shot.phase === 'searching' && shot.activity !== null;

  // ⑪: the streaming state the send path writes (stream registered, activity external_search, its query chip).
  useLayoutEffect(() => {
    if (!searching || !shot.activity) return;
    const store = getVanillaStore();
    store.getState().beginStreamingForConversation(SHOTS_CONVERSATION_ID, assistant.id);
    store.getState().setStreamingActivity(SHOTS_CONVERSATION_ID, 'external_search');
    applyExternalSearchActivity(SHOTS_CONVERSATION_ID, shot.activity);
    return () => {
      clearExternalSearchActivity(SHOTS_CONVERSATION_ID);
      store.getState().clearStreamingForConversation(SHOTS_CONVERSATION_ID);
    };
  }, [searching, shot.activity, assistant.id]);

  return (
    <SearchServicesOverride.Provider value={local}>
      <div style={FRAME}>
        <MessageBubble message={user} />
        <MessageBubble
          message={assistant}
          sameSpeaker={false}
          isLastMessage
          searchSourcesExpanded={shot.sourcesExpanded}
          onRegenerateWithSearch={() => undefined}
          {...(shot.phase === 'searching' ? { streamingText: '' } : {})}
        />
      </div>
    </SearchServicesOverride.Provider>
  );
}
