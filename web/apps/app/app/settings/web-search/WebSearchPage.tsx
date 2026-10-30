'use client';

// Settings › Web Search: my search services, add sheet, service detail.

import { useCallback, useEffect, useMemo, useState } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import { useRouter } from 'next/navigation';
import { ChevronRight, Plus } from 'lucide-react';
import { BackButton } from '@oriveo/ui';
import { useAppStore } from '../../../providers/StoreProvider';
import { FEATURE_BADGE_IDS, markSeen } from '../../../lib/core/feature-badges';
import { getActiveUID } from '../../../lib/infra/storage/partition';
import {
  loadSearchServicesSnapshot,
  loadSettingsCatalog,
  searchConnectionsFromProviders,
  type SearchConnectionOption,
  type SearchServicesSnapshot,
  type SearchServiceView,
  type SettingsCatalog,
} from '../../../lib/search/search-settings-data';
import { AddSearchServiceSheet, type AddSheetInitial } from './AddSearchServiceSheet';
import { notifySearchServicesChanged } from '../../../lib/search/external-search-context';
import type { TestGateState } from './use-test-gate';
import { SearchServiceDetail } from './SearchServiceDetail';
import { searchServiceRowSubtitle, SearchServiceLogo } from './WebSearchParts';
import styles from './WebSearch.module.css';

/**
 * In-memory data for the dev shots (`/dev/webSearch-shots/*`). Production passes nothing and reads the
 * partition store, the adopted catalog and the model connections as usual.
 */
export interface WebSearchPageSource {
  uid: string;
  catalog: SettingsCatalog;
  snapshot: SearchServicesSnapshot;
  connections: SearchConnectionOption[];
  addSheet?: AddSheetInitial;
  detail?: { id: string; test?: TestGateState };
}

export function WebSearchPage({ source }: { source?: WebSearchPageSource } = {}) {
  const t = useTranslations('webSearch');
  const tCommon = useTranslations('common');
  const locale = useLocale();
  const router = useRouter();
  const providers = useAppStore((s) => s.providers);
  const storeConnections = useMemo(() => searchConnectionsFromProviders(providers ?? []), [providers]);
  const connections = source?.connections ?? storeConnections;
  const [uid, setUid] = useState<string | null>(source?.uid ?? null);
  const [catalog, setCatalog] = useState<SettingsCatalog | null>(source?.catalog ?? null);
  const [snapshot, setSnapshot] = useState<SearchServicesSnapshot | null>(source?.snapshot ?? null);
  const [addOpen, setAddOpen] = useState(!!source?.addSheet);
  const [detailId, setDetailId] = useState<string | null>(source?.detail?.id ?? null);
  // Chat search error card deep link: ?service=<record id>&focus=key|edit|reconfirm (unknown id = the list).
  const [detailFocus, setDetailFocus] = useState<'key' | 'edit' | 'reconfirm' | undefined>(undefined);
  useEffect(() => {
    if (source) return;
    const params = new URLSearchParams(window.location.search);
    const service = params.get('service');
    if (!service) return;
    const focus = params.get('focus');
    setDetailId(service);
    setDetailFocus(focus === 'key' || focus === 'edit' || focus === 'reconfirm' ? focus : undefined);
    // Mount only.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    markSeen(FEATURE_BADGE_IDS.settingsWebSearch);
  }, []);

  useEffect(() => {
    if (source) return;
    let cancelled = false;
    void Promise.all([getActiveUID(), loadSettingsCatalog()]).then(([activeUid, loaded]) => {
      if (cancelled) return;
      setUid(activeUid);
      setCatalog(loaded);
    });
    return () => {
      cancelled = true;
    };
  }, []);

  const reload = useCallback(async () => {
    if (!uid || source) return;
    setSnapshot(await loadSearchServicesSnapshot(uid, catalog, connections));
  }, [uid, catalog, connections, source]);

  useEffect(() => {
    void reload();
  }, [reload]);

  const services = snapshot?.services ?? [];
  const detail = detailId ? services.find((s) => s.record.id === detailId) ?? null : null;

  if (uid && detail && snapshot) {
    return (
      <SearchServiceDetail
        key={detail.record.id}
        initialTest={source?.detail?.id === detail.record.id ? source.detail.test : undefined}
        uid={uid}
        view={detail}
        catalog={catalog}
        connections={connections}
        services={services}
        isDefault={snapshot.defaultId === detail.record.id}
        onChanged={() => { notifySearchServicesChanged(); void reload(); }}
        onDeleted={() => {
          setDetailId(null);
          notifySearchServicesChanged();
          void reload();
        }}
        onBack={() => { setDetailId(null); setDetailFocus(undefined); }}
        initialFocus={detailFocus}
      />
    );
  }

  const subtitleOf = (view: SearchServiceView) => searchServiceRowSubtitle(t, locale, catalog, view);

  return (
    <div className={styles.page} data-testid="web-search-page">
      <BackButton className={styles.backLink} label={tCommon('back')} onClick={() => router.push('/settings')} />
      <h1 className={styles.title}>{t('entry.title')}</h1>
      <p className={styles.intro}>{t('main.intro')}</p>

      <section className={styles.group}>
        <h2 className={styles.groupTitle}>{t('main.section')}</h2>
        <div className={styles.card} data-testid="web-search-list">
          {snapshot && services.length === 0 ? <p className={styles.cardNote}>{t('main.empty')}</p> : null}
          {services.map((view) => {
            const subtitle = subtitleOf(view);
            return (
              <button key={view.record.id} type="button" className={styles.row} data-service-row={view.record.id} onClick={() => setDetailId(view.record.id)}>
                <SearchServiceLogo serviceId={view.record.kind === 'preset' ? view.record.serviceId : null} />
                <span className={styles.rowText}>
                  <span className={styles.rowTitle}>
                    {view.name}
                    {snapshot?.defaultId === view.record.id ? <span className={styles.badge}>{t('badge.default')}</span> : null}
                    {view.record.kind === 'custom' ? <span className={styles.badgeMuted}>{t('badge.custom')}</span> : null}
                  </span>
                  <span className={subtitle.warning ? styles.rowSubtitleWarning : styles.rowSubtitle}>{subtitle.text}</span>
                </span>
                <ChevronRight className={styles.chevron} size={18} aria-hidden />
              </button>
            );
          })}
          <button type="button" className={styles.addRow} disabled={!uid} onClick={() => setAddOpen(true)}>
            <Plus size={20} aria-hidden />
            {t('main.add')}
          </button>
        </div>
        <p className={styles.footer}>{t('main.footer')}</p>
      </section>

      {uid ? (
        <AddSearchServiceSheet
          initial={source?.addSheet}
          open={addOpen}
          onClose={() => setAddOpen(false)}
          uid={uid}
          catalog={catalog}
          connections={connections}
          services={services}
          onSaved={() => { notifySearchServicesChanged(); void reload(); }}
          onOpenService={(id) => setDetailId(id)}
        />
      ) : null}
    </div>
  );
}
