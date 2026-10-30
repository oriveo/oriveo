'use client';

// Shared pieces of the web search settings screens: logo, price line, consent card, test result.

import type { ReactNode } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import { AlertTriangle, ArrowUpRight, Check, CircleDollarSign, Loader2, Send } from 'lucide-react';
import { searchPriceSummary, type SearchConsentLine, type SearchPriceSummary, type SearchServiceStatus, type SearchTestPresentation } from '@oriveo/core/search/search-settings';
import { resolveOfficialProviderLogo } from '../../../components/provider-logo-assets';
import { useIsDarkTheme } from '../../../lib/hooks/useIsDarkTheme';
import { camelKey, type SearchServiceView, type SettingsCatalog } from '../../../lib/search/search-settings-data';
import styles from './WebSearch.module.css';

type Translate = ReturnType<typeof useTranslations>;

const WARNING_SUBTITLE: Record<Exclude<SearchServiceStatus, 'ready'>, string> = {
  connection_missing: 'row.connectionMissing',
  needs_key: 'row.needsKey',
  host_changed: 'row.hostChanged',
  withdrawn: 'row.withdrawn',
  catalog_unavailable: 'row.catalogUnavailable',
};

/**
 * Row subtitle for a saved service (settings list and the chat «Search via» sheet): warning status first,
 * then the reused connection, then connected + price.
 */
export function searchServiceRowSubtitle(
  t: Translate,
  locale: string,
  catalog: SettingsCatalog | null,
  view: SearchServiceView,
): { text: string; warning: boolean } {
  const { row, record } = view;
  if (row.status !== 'ready') return { text: t(WARNING_SUBTITLE[row.status]), warning: true };
  if (row.keySource === 'connection') return { text: t('row.viaConnection', { name: row.connectionName ?? '' }), warning: false };
  if (record.kind === 'custom') return { text: t(row.keySource === 'own' ? 'row.connected' : 'row.noKey'), warning: false };
  const entry = catalog?.entries.find((e) => e.id === record.serviceId);
  const price = entry ? priceSummaryText(t, locale, searchPriceSummary(entry, record.regionId)) : '';
  return { text: [t('row.connected'), price].filter(Boolean).join(' · '), warning: false };
}

/** Catalog serviceId → existing provider logo kind (light + dark artwork). */
const PROVIDER_LOGO_KIND: Record<string, string> = { deepseek: 'deepseek', zhipu: 'zhipu', kimi: 'moonshot' };
/** Catalog serviceId → imported 96 px logo. */
const IMPORTED_LOGO: Record<string, string> = {
  tavily: '/search-logos/tavily.png',
  exa: '/search-logos/exa.png',
  brave: '/search-logos/brave.png',
  perplexity: '/search-logos/perplexity.png',
};

function ServerGlyph({ size }: { size: number }) {
  return (
    <svg className={styles.serverGlyph} width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden data-search-logo="server">
      <rect x="3" y="4" width="18" height="7" rx="2" />
      <rect x="3" y="13" width="18" height="7" rx="2" />
      <path d="M7 7.5h.01M7 16.5h.01" />
    </svg>
  );
}

/** Preset logo by catalog id; unknown ids and custom services use the server glyph. No frame, no plate. */
/** Logo of the model's own connection (the «Built into model» row of the chat «Search via» page). */
export function ModelProviderLogo({ providerKind, size = 28 }: { providerKind: string | null; size?: number }) {
  const isDark = useIsDarkTheme();
  const src = providerKind ? resolveOfficialProviderLogo(providerKind, isDark) : undefined;
  if (!src) return <ServerGlyph size={size} />;
  // eslint-disable-next-line @next/next/no-img-element
  return <img className={styles.logo} src={src} width={size} height={size} alt="" aria-hidden data-provider-logo={providerKind ?? ''} />;
}

export function SearchServiceLogo({ serviceId, size = 28 }: { serviceId: string | null; size?: number }) {
  const isDark = useIsDarkTheme();
  const providerKind = serviceId ? PROVIDER_LOGO_KIND[serviceId] : undefined;
  const src = providerKind ? resolveOfficialProviderLogo(providerKind, isDark) : serviceId ? IMPORTED_LOGO[serviceId] : undefined;
  if (!src) return <ServerGlyph size={size} />;
  // eslint-disable-next-line @next/next/no-img-element
  return <img className={styles.logo} src={src} width={size} height={size} alt="" aria-hidden data-search-logo={serviceId ?? ''} />;
}

/** Price summary text: unit price, free allowance + card note, optional "international site". */
export function priceSummaryText(
  t: Translate,
  locale: string,
  summary: SearchPriceSummary,
  { otherRegion = false }: { otherRegion?: boolean } = {},
): string {
  const parts: string[] = [];
  if (summary.price) {
    parts.push(t(summary.price.unit === 'per_1k_requests' ? 'price.per1k' : 'price.perRequest', { price: summary.price.label }));
  }
  if (summary.free) {
    parts.push(summary.free.kind === 'monthly_credits'
      ? t('price.freeCredits', { count: new Intl.NumberFormat(locale).format(summary.free.count ?? 0) })
      : t('price.freeUsd', { price: summary.free.amountLabel ?? '' }));
    parts.push(t(summary.free.cardRequired ? 'price.cardRequired' : 'price.noCard'));
  }
  if (otherRegion && summary.otherRegionCount > 0) parts.push(t('price.otherRegion'));
  return parts.join(' · ');
}

const CONSENT_ICON: Record<SearchConsentLine['key'], ReactNode> = {
  customUnverified: <AlertTriangle size={16} />,
  sendsQuery: <Send size={16} />,
  sendsQueryCustom: <Send size={16} />,
  billing: <CircleDollarSign size={16} />,
  billingCustom: <CircleDollarSign size={16} />,
  webForwarded: <Send size={16} />,
  testOnce: <Check size={16} />,
  testOnceSave: <Check size={16} />,
};

export function ConsentCard({ lines }: { lines: SearchConsentLine[] }) {
  const t = useTranslations('webSearch');
  return (
    <section className={styles.consentCard} aria-labelledby="web-search-consent-title">
      <h3 id="web-search-consent-title" className={styles.consentTitle}>{t('consent.title')}</h3>
      <ul className={styles.consentList}>
        {lines.map((line) => (
          <li key={line.key} className={styles.consentLine} data-consent-line={line.key} data-warning={line.key === 'customUnverified' || undefined}>
            <span className={styles.consentIcon} aria-hidden>{CONSENT_ICON[line.key]}</span>
            <span>{t(`consent.${line.key}`, line.args as Record<string, string>)}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}

/** Failed test: error headline + the settings-page action (none for withdrawn services). */
export function TestFailure({
  presentation,
  onAction,
  disabled,
}: {
  presentation: Extract<SearchTestPresentation, { state: 'failed' }>;
  onAction: (action: Extract<SearchTestPresentation, { state: 'failed' }>['action']) => void;
  disabled?: boolean;
}) {
  const t = useTranslations('webSearch');
  return (
    <div className={styles.testFailure} role="alert" data-testid="web-search-test-failure">
      <span className={styles.testFailureText}>{t(`error.${camelKey(presentation.headline)}`)}</span>
      {presentation.action !== 'none' ? (
        <button type="button" className={styles.inlineAction} disabled={disabled} onClick={() => onAction(presentation.action)}>
          {t(`action.${camelKey(presentation.action)}`)}
        </button>
      ) : null}
    </div>
  );
}

/** Detail page result line: green "Passed · 0.8 s · 5 results" or red "Failed: …". */
export function TestResultLine({ presentation }: { presentation: SearchTestPresentation }) {
  const t = useTranslations('webSearch');
  const locale = useLocale();
  if (presentation.state === 'passed') {
    const seconds = new Intl.NumberFormat(locale, { minimumFractionDigits: 1, maximumFractionDigits: 1 }).format(presentation.latencyTenths / 10);
    return (
      <span className={styles.testPassed} data-testid="web-search-test-passed">
        {t('test.passed', { seconds, count: String(presentation.count) })}
      </span>
    );
  }
  return (
    <span className={styles.testFailed} data-testid="web-search-test-failed">
      {t('test.failed', { reason: t(`error.${camelKey(presentation.headline)}`) })}
    </span>
  );
}

export function Spinner() {
  return <Loader2 className={styles.spinner} size={18} aria-hidden />;
}

export function ExternalLink({ href, children }: { href: string; children: ReactNode }) {
  return (
    <a className={styles.link} href={href} target="_blank" rel="noopener noreferrer">
      {children}
      <ArrowUpRight size={14} aria-hidden />
    </a>
  );
}
