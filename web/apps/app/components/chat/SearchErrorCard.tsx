'use client';

/**
 * External web search error card. Reads the persisted searchErrorCard;
 * buttons and their behavior come from searchErrorCardPresentation. Local facts (does the service still exist,
 * its pricing page) are read from the search partition, or from SearchServicesOverride in the dev shots.
 */
import { createContext, useContext, useEffect, useState } from 'react';
import { useTranslations } from 'next-intl';
import { useRouter } from 'next/navigation';
import { AlertTriangle, ExternalLink } from 'lucide-react';
import type { ChatMessage, Conversation } from '@oriveo/shared';
import { regionLinks } from '@oriveo/core/search/search-catalog';
import { SEARXNG_SETUP_GUIDE_URL } from '@oriveo/core/search/search-settings';
import { useAppStore } from '../../providers/StoreProvider';
import { searchConnectionsFromProviders, type SearchServiceView, type SettingsCatalog } from '../../lib/search/search-settings-data';
import {
  OPEN_SEARCH_SOURCE_PICKER_EVENT,
  searchErrorCardPresentation,
  webSearchSettingsHref,
  type SearchErrorButton,
  type SearchErrorLocalFacts,
} from '../../lib/search/search-chat-presentation';
import styles from './SearchErrorCard.module.css';

type ErrorCardRecord = NonNullable<ChatMessage['searchErrorCard']>;

export interface SearchServicesOverrideValue {
  services: readonly SearchServiceView[];
  catalog: SettingsCatalog;
}

/** Dev shots: local search services without touching the partition store. */
export const SearchServicesOverride = createContext<SearchServicesOverrideValue | null>(null);

export function searchErrorLocalFacts(card: ErrorCardRecord, data: SearchServicesOverrideValue | null): SearchErrorLocalFacts {
  const view = data?.services.find((s) => s.record.id === card.serviceId) ?? null;
  const record = view?.record;
  const entry = record?.kind === 'preset' ? data?.catalog.entries.find((e) => e.id === record.serviceId) ?? null : null;
  return {
    serviceExists: view !== null,
    pricingHref: entry && record?.kind === 'preset' ? regionLinks(entry, record.regionId).pricing ?? null : null,
    switchToExists: card.switchTo ? Boolean(data?.services.some((s) => s.record.id === card.switchTo?.id)) : false,
    setupGuideHref: SEARXNG_SETUP_GUIDE_URL,
  };
}

function useLocalSearchServices(): SearchServicesOverrideValue | null {
  const override = useContext(SearchServicesOverride);
  const providers = useAppStore((s) => s.providers);
  const [loaded, setLoaded] = useState<SearchServicesOverrideValue | null>(null);
  useEffect(() => {
    if (override) return;
    let cancelled = false;
    void import('../../lib/search/external-search-context')
      .then(({ loadExternalSearchDataForSend }) => loadExternalSearchDataForSend(searchConnectionsFromProviders(providers ?? [])))
      .then((data) => {
        if (!cancelled) setLoaded(data ? { services: data.snapshot.services, catalog: data.catalog } : { services: [], catalog: { available: false, entries: [], withdrawn: [] } });
      })
      .catch(() => {
        if (!cancelled) setLoaded({ services: [], catalog: { available: false, entries: [], withdrawn: [] } });
      });
    return () => {
      cancelled = true;
    };
  }, [override, providers]);
  return override ?? loaded;
}

/** Answer again with switchTo: pick_service on this conversation × its current model, then regenerate + re-search. */
async function pickSearchService(conversation: Conversation, serviceId: string, serviceName: string): Promise<void> {
  const [{ getActiveUID }, { getConversationSearchSource }, { externalSearchModelKey, writeConversationSearchSource }] = await Promise.all([
    import('../../lib/infra/storage/partition'),
    import('../../lib/search/search-service-store'),
    import('../../lib/search/external-search-context'),
  ]);
  const uid = await getActiveUID();
  const stored = await getConversationSearchSource(uid, conversation.id);
  await writeConversationSearchSource({
    uid,
    conversationId: conversation.id,
    stored,
    modelKey: externalSearchModelKey(conversation.providerID, conversation.modelID),
    event: { type: 'pick_service', serviceId, serviceName },
  });
}

export function SearchErrorCard({
  card,
  isLastMessage,
  conversation,
  disabled = false,
  onRegenerateWithSearch,
}: {
  card: ErrorCardRecord;
  isLastMessage: boolean;
  conversation?: Conversation;
  disabled?: boolean;
  onRegenerateWithSearch?: () => void;
}) {
  const t = useTranslations('webSearch');
  const router = useRouter();
  const data = useLocalSearchServices();
  const canRegenerate = Boolean(onRegenerateWithSearch);
  const presentation = searchErrorCardPresentation(card, {
    isLastMessage: isLastMessage && canRegenerate,
    ...searchErrorLocalFacts(card, data),
  });
  const [busy, setBusy] = useState(false);

  const run = async (button: SearchErrorButton) => {
    const behavior = button.behavior;
    switch (behavior.kind) {
      case 'open_service':
      case 'open_settings':
        router.push(webSearchSettingsHref(behavior));
        return;
      case 'regenerate':
        onRegenerateWithSearch?.();
        return;
      case 'open_search_source_picker':
        window.dispatchEvent(new CustomEvent(OPEN_SEARCH_SOURCE_PICKER_EVENT));
        return;
      case 'answer_with':
        if (!conversation || !onRegenerateWithSearch) return;
        setBusy(true);
        try {
          await pickSearchService(conversation, behavior.serviceId, behavior.serviceName);
          onRegenerateWithSearch();
        } finally {
          setBusy(false);
        }
        return;
      default:
    }
  };

  const renderButton = (button: SearchErrorButton, primary: boolean) => {
    const label = t(button.labelKey, button.labelValues);
    const className = primary ? styles.primary : styles.secondary;
    if (button.behavior.kind === 'external') {
      return (
        <a className={className} href={button.behavior.href} target="_blank" rel="noopener noreferrer">
          {label}
          <ExternalLink size={13} aria-hidden="true" className="rtl-mirror" />
        </a>
      );
    }
    return (
      <button type="button" className={className} disabled={disabled || busy} onClick={() => void run(button)}>
        {label}
      </button>
    );
  };

  return (
    <div className={styles.card} role="group" aria-label={t(presentation.titleKey, presentation.titleValues)} data-testid="search-error-card">
      <AlertTriangle size={18} aria-hidden="true" className={styles.icon} />
      <div className={styles.body}>
        <p className={styles.title}>{t(presentation.titleKey, presentation.titleValues)}</p>
        <p className={styles.detail}>{t(presentation.detailKey)}</p>
        {data && (presentation.primary || presentation.secondary) ? (
          <div className={styles.actions}>
            {presentation.primary ? renderButton(presentation.primary, true) : null}
            {presentation.secondary ? renderButton(presentation.secondary, false) : null}
          </div>
        ) : null}
      </div>
    </div>
  );
}
