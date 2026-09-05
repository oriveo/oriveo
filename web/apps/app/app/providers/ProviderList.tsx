'use client';

import { useMemo, useState, useCallback, useEffect, useRef } from 'react';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { Activity, Layers, Plus, Wallet, type LucideIcon } from 'lucide-react';
import type { Provider } from '@oriveo/shared';
import { useAppStore } from '../../providers/StoreProvider';
import { ProvidersClusterHeader } from '../../components/providers/ProvidersClusterHeader';
import { ProviderListCard } from '../../components/providers/ProviderListCard';
import { ProviderHeroCard } from '../../components/providers/ProviderHeroCard';
import { ProviderCostSummaryCard } from '../../components/providers/ProviderCostSummaryCard';
import { selectResolvedCatalog } from '../../lib/core/store/selectors';
import { getEffectiveStatusKind } from '../../lib/core/providers/provider-status';
import { onVersionChange } from '../../lib/core/metadata/metadata-client';
import {
  buildMonthlyCostByProvider,
  buildMonthlyCostSummary,
} from '../../lib/core/cost/cost-summary';
import {
  getCachedFullMonthlyCost,
  refreshFullMonthlyCost,
  subscribeFullMonthlyCost,
  type FullMonthlyCost,
} from '../../lib/core/cost/full-monthly-cost-cache';
import {
  getProviderBalanceCached,
  isBalanceCapable,
  type ProviderBalance,
} from '../../lib/core/providers/balance';
import { COST_EPSILON } from '../../lib/utils/format-utils';
import styles from './ProviderList.module.css';

type ProviderSectionTone = 'active' | 'all' | 'costs';

function ProviderSectionHeader({
  title,
  icon: Icon,
  tone,
}: {
  title: string;
  icon: LucideIcon;
  tone: ProviderSectionTone;
}) {
  return (
    <div
      className={styles.sectionHeader}
      data-tone={tone}
      data-testid={`providers-section-${tone}`}
    >
      <span className={styles.sectionHeaderIcon} data-section-icon={tone} aria-hidden="true">
        <Icon size={16} strokeWidth={2.25} />
      </span>
      <span>{title}</span>
    </div>
  );
}

function statusPriority(kind: 'connected' | 'syncing' | 'issue' | 'needsKey'): number {
  if (kind === 'connected') return 0;
  if (kind === 'syncing') return 1;
  return 2;
}

export function ProviderList() {
  const router = useRouter();
  const t = useTranslations('pages.providerList');
  const providers = useAppStore((s) => s.providers);
  const conversations = useAppStore((s) => s.conversations);
  const hydrationPhase = useAppStore((s) => s.hydrationPhase);
  const [providerBalancesById, setProviderBalancesById] = useState<Map<string, ProviderBalance>>(
    () => new Map(),
  );
  const [metadataTick, setMetadataTick] = useState(0);
  useEffect(() => {
    const unsubscribe = onVersionChange(() => setMetadataTick((tick) => tick + 1));
    return unsubscribe;
  }, []);
  const listedProviders = providers;
  const totalAvailableModels = useMemo(
    () => listedProviders.reduce((sum, p) => sum + selectResolvedCatalog(p).availableModelCount, 0),
    [listedProviders, metadataTick],
  );
  const [fullLocalCost, setFullLocalCost] = useState<FullMonthlyCost | null>(getCachedFullMonthlyCost);
  const storeBuiltFallback = useMemo(() => ({
    monthlyCostByProvider: buildMonthlyCostByProvider(conversations),
    localMonthlyCostSummary: buildMonthlyCostSummary(conversations, listedProviders),
  }), [conversations, listedProviders]);
  const monthlyCostByProvider = fullLocalCost?.byProvider ?? storeBuiltFallback.monthlyCostByProvider;
  const monthlyCostSummary = fullLocalCost?.summary ?? storeBuiltFallback.localMonthlyCostSummary;

  const spotlightProvider = useMemo<Provider | null>(() => {
    if (listedProviders.length === 0) return null;
    const withCost = listedProviders
      .map((p) => ({ provider: p, cost: monthlyCostByProvider.get(p.id) ?? 0 }))
      .filter((x) => x.cost > COST_EPSILON)
      .sort((a, b) => b.cost - a.cost);
    if (withCost.length > 0) return withCost[0].provider;
    const sorted = [...listedProviders].sort((a, b) => statusPriority(getEffectiveStatusKind(a)) - statusPriority(getEffectiveStatusKind(b)));
    return sorted[0] ?? null;
  }, [listedProviders, monthlyCostByProvider]);

  const listedProvidersIdentityKey = useMemo(
    () => listedProviders
      .map((p) => `${p.id}~${p.customName ?? ''}~${p.baseURLText ?? ''}`)
      .join('|'),
    [listedProviders],
  );
  const listedProvidersRef = useRef(listedProviders);
  listedProvidersRef.current = listedProviders;
  const providerBalancesRefreshKey = useMemo(
    () => listedProviders
      .filter((provider) => isBalanceCapable(provider.kind))
      .map((provider) => [
        provider.id,
        provider.kind,
        provider.apiKey,
        provider.baseURLText ?? '',
      ].join('~'))
      .join('|'),
    [listedProviders],
  );

  useEffect(() => {
    let cancelled = false;
    const candidates = listedProvidersRef.current.filter(
      (provider) => isBalanceCapable(provider.kind) && provider.apiKey.trim().length > 0,
    );
    const candidateIDs = new Set(candidates.map((provider) => provider.id));

    setProviderBalancesById((previous) => {
      if (previous.size === 0) return previous;
      const next = new Map(previous);
      for (const providerID of next.keys()) {
        if (!candidateIDs.has(providerID)) next.delete(providerID);
      }
      return next;
    });

    void Promise.all(candidates.map(async (provider) => {
      try {
        const balance = await getProviderBalanceCached(
          provider.id,
          provider.kind,
          provider.apiKey,
          provider.baseURLText,
          false,
        );
        return [provider.id, balance] as const;
      } catch {
        return [provider.id, null] as const;
      }
    })).then((results) => {
      if (cancelled) return;
      setProviderBalancesById((previous) => {
        const next = new Map(previous);
        for (const [providerID, balance] of results) {
          if (balance) next.set(providerID, balance);
        }
        return next;
      });
    });

    return () => { cancelled = true; };
  }, [providerBalancesRefreshKey]);

  const conversationsCostKey = useMemo(() => {
    let maxUpdated = 0;
    for (const conversation of conversations) {
      const parsed = Date.parse(conversation.updatedAt);
      if (Number.isFinite(parsed) && parsed > maxUpdated) maxUpdated = parsed;
    }
    return `${conversations.length}|${Math.floor(maxUpdated / 1000)}`;
  }, [conversations]);
  const conversationsRef = useRef(conversations);
  conversationsRef.current = conversations;

  useEffect(() => {
    const unsubscribe = subscribeFullMonthlyCost(() => {
      setFullLocalCost(getCachedFullMonthlyCost());
    });
    void refreshFullMonthlyCost(listedProvidersRef.current, conversationsRef.current).then((next) => {
      if (next) setFullLocalCost(next);
    });
    return unsubscribe;
  }, [listedProvidersIdentityKey, conversationsCostKey]);

  const hasPersistedProviders = listedProviders.length > 0;

  return (
    <div className={styles.pageWrapper}>
      <div className={styles.pageBackground} aria-hidden />

      <div className={styles.page}>
        <div className={styles.headerBar}>
          <span className={styles.headerTitle}>{t('title')}</span>
          <button
            className={styles.addCircleButton}
            onClick={() => router.push('/providers/new')}
            aria-label={t('addProvider')}
          >
            <Plus size={18} strokeWidth={2.6} aria-hidden="true" />
          </button>
        </div>

        {hydrationPhase !== 'ready' && providers.length === 0 ? (
          <div className={styles.cluster} data-testid="providers-cluster">
            <div className={styles.empty} data-testid="providers-skeleton" aria-busy="true">
              <div className={styles.emptyTitle}>{t('noProviders')}</div>
            </div>
          </div>
        ) : hasPersistedProviders ? (
          <>
            {spotlightProvider && (
              <section className={styles.spotlightSection}>
                <ProviderSectionHeader title={t('activeThisMonth')} icon={Activity} tone="active" />
                <ProviderHeroCard
                  provider={spotlightProvider}
                  monthlyCost={monthlyCostByProvider.get(spotlightProvider.id) ?? 0}
                  dailyCostsLast7Days={[]}
                  onClick={() => router.push(`/providers/${spotlightProvider.id}`)}
                />
              </section>
            )}

            <ProvidersClusterHeader providers={listedProviders} totalAvailableModels={totalAvailableModels} />

            <section className={styles.allProvidersSection}>
              <ProviderSectionHeader title={t('allProviders')} icon={Layers} tone="all" />
              <div className={styles.cluster} data-testid="providers-cluster">
                <div className={styles.cardList}>
                  {listedProviders.map((provider) => (
                    <ProviderListCard
                      key={provider.id}
                      provider={provider}
                      monthlyCost={monthlyCostByProvider.get(provider.id) ?? 0}
                      providerBalance={providerBalancesById.get(provider.id)}
                      onClick={() => router.push(`/providers/${provider.id}`)}
                    />
                  ))}
                </div>
              </div>
            </section>
          </>
        ) : (
          <div className={styles.cluster} data-testid="providers-cluster">
            <div className={styles.empty}>
              <svg className={styles.emptyIcon} width="30" height="30" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                <path d="M12 2L2 7l10 5 10-5-10-5z" />
                <path d="M2 17l10 5 10-5" />
                <path d="M2 12l10 5 10-5" />
              </svg>
              <div className={styles.emptyTitle}>{t('noProviders')}</div>
              <div className={styles.emptyHint}>{t('noProvidersHint')}</div>
            </div>
          </div>
        )}

        {monthlyCostSummary.isVisible && (
          <section className={styles.costSection}>
            <ProviderSectionHeader title={t('costsTitle')} icon={Wallet} tone="costs" />
            <ProviderCostSummaryCard
              summary={monthlyCostSummary}
            />
          </section>
        )}
      </div>
    </div>
  );
}
