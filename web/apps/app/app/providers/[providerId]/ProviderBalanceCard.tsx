'use client';

/**
 * Balance card for the four BYOK providers that support fetchBalance.
 *
 * Rendering conditions: the caller has already guarded with `isBalanceCapable(provider.kind)`;
 * a 401 (OpenRouter management key required) hides the card silently; a network error shows
 * "could not load, try again" with a tappable retry.
 *
 * Labels: Granted / Top-up / Used / Voucher / Cash / Owing.
 *
 * Visual details:
 *   - 20px corner radius with a two-layer shadow
 *   - background: surface plus a purple radial in the top right, a glass light streak and a
 *     PieChart watermark in the bottom right
 *   - header: 32px primarySoft chip with a CreditCard icon, the title, and a 32px round purple
 *     refresh button
 *   - main amount at 32px with tabular-nums plus a currency footnote
 *   - progress bar: 6px primarySoft track with a solid primary fill
 *   - breakdown: 22px round Lucide icon chips in two columns of title/value
 *
 * Refresh behavior: with data already on screen the placeholder is not swapped back in and only the
 * refresh icon spins, which avoids a height collapse; a failed refresh keeps the previous balance.
 */

import { useCallback, useEffect, useState } from 'react';
import { useTranslations } from 'next-intl';
import {
  AlertTriangle,
  ArrowDownCircle,
  ArrowUpCircle,
  CreditCard,
  PieChart,
  RefreshCw,
  Sparkles,
} from 'lucide-react';
import type { Provider, ProviderKind } from '@oriveo/shared';
import {
  BalanceUnauthorizedError,
  BalanceUnsupportedError,
  getProviderBalanceCached,
  isBalanceCapable,
  type ProviderBalance,
} from '../../../lib/core/providers/balance';
import styles from './ProviderBalanceCard.module.css';

interface ProviderBalanceCardProps {
  provider: Provider;
}

interface State {
  status: 'loading' | 'ready' | 'error' | 'hidden';
  balance?: ProviderBalance;
  errorMessage?: string;
  isKeyInvalid?: boolean;
}

function formatAmount(currency: ProviderBalance['currency'], value: number): string {
  const sign = value < 0 ? '-' : '';
  const abs = Math.abs(value);
  // CNY uses 2 decimals; a USD balance can be very small (< $0.01), so allow up to 4 and trim trailing zeros
  const digits = currency === 'CNY' ? 2 : abs < 0.01 ? 4 : 2;
  return `${currency === 'USD' ? '$' : '¥'}${sign}${abs.toLocaleString(undefined, {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  })}`;
}

/** Used share = used / (used + remaining); null when there is no totalUsage or it is not positive */
function usageProgress(b: ProviderBalance): number | null {
  if (b.totalUsage == null || b.totalUsage <= 0) return null;
  const denom = b.total + b.totalUsage;
  if (denom <= 0) return null;
  return Math.min(Math.max(b.totalUsage / denom, 0), 1);
}

export function ProviderBalanceCard({ provider }: ProviderBalanceCardProps) {
  const t = useTranslations('pages.providerDetail.balanceCard');
  const [state, setState] = useState<State>({ status: 'loading' });

  const load = useCallback(
    async (bypassCache: boolean) => {
      if (!isBalanceCapable(provider.kind)) {
        setState({ status: 'hidden' });
        return;
      }
      if (!provider.apiKey) {
        setState({ status: 'hidden' });
        return;
      }
      setState((prev) =>
        prev.balance ? { status: 'loading', balance: prev.balance } : { status: 'loading' },
      );
      try {
        const balance = await getProviderBalanceCached(
          provider.id,
          provider.kind,
          provider.apiKey,
          provider.baseURLText,
          bypassCache,
        );
        setState({ status: 'ready', balance });
      } catch (err) {
        if (err instanceof BalanceUnsupportedError) {
          setState({ status: 'hidden' });
          return;
        }
        // A failed refresh with existing data keeps showing the old balance.
        // Only a failed first load switches to the error placeholder.
        if (err instanceof BalanceUnauthorizedError) {
          setState((prev) =>
            prev.balance
              ? { status: 'ready', balance: prev.balance }
              : { status: 'error', errorMessage: t('errorInvalidKey'), isKeyInvalid: true },
          );
          return;
        }
        setState((prev) =>
          prev.balance
            ? { status: 'ready', balance: prev.balance }
            : { status: 'error', errorMessage: t('errorNetwork'), isKeyInvalid: false },
        );
      }
    },
    [provider.apiKey, provider.baseURLText, provider.id, provider.kind, t],
  );

  useEffect(() => {
    void load(false);
  }, [load]);

  if (state.status === 'hidden') return null;

  const isRefreshing = state.status === 'loading';
  const isFirstLoading = isRefreshing && !state.balance;
  const showError = state.status === 'error';

  return (
    <div className={styles.card}>
      <div className={styles.watermark} aria-hidden="true">
        <PieChart strokeWidth={1.4} />
      </div>

      <div className={styles.content}>
        <div className={styles.header}>
          <div className={styles.iconChip} aria-hidden="true">
            <CreditCard size={14} strokeWidth={2.4} />
          </div>
          <div className={styles.title}>{t('title')}</div>
          <button
            type="button"
            className={styles.refreshBtn}
            data-refreshing={isRefreshing ? 'true' : 'false'}
            onClick={() => void load(true)}
            disabled={isRefreshing}
            aria-label={t('refresh')}
          >
            <RefreshCw size={14} strokeWidth={2.4} aria-hidden="true" />
          </button>
        </div>

        {showError && !state.balance ? (
          <ErrorContent
            isKeyInvalid={!!state.isKeyInvalid}
            message={state.errorMessage ?? ''}
            onRetry={() => void load(true)}
            t={t}
          />
        ) : isFirstLoading ? (
          <SkeletonContent />
        ) : state.balance ? (
          <BalanceContent balance={state.balance} providerKind={provider.kind} t={t} />
        ) : null}
      </div>
    </div>
  );
}

function BalanceContent({
  balance,
  providerKind,
  t,
}: {
  balance: ProviderBalance;
  providerKind: ProviderKind;
  t: ReturnType<typeof useTranslations>;
}) {
  const { granted, topUp, totalUsage, currency } = balance;
  const showGranted = granted != null && granted !== 0;
  const showTopUp = topUp != null && topUp !== 0;
  const showUsage = totalUsage != null && totalUsage !== 0;
  const showBreakdown = showGranted || showTopUp || showUsage;
  const isMoonshotOwing = providerKind === 'moonshot' && topUp != null && topUp < 0;
  const progress = usageProgress(balance);

  return (
    <>
      <div className={styles.amount}>
        <span className={styles.amountValue}>{formatAmount(currency, balance.total)}</span>
        <span className={styles.amountCurrency}>{currency}</span>
      </div>

      {showBreakdown && (
        <div className={styles.breakdownGroup}>
          {progress != null && (
            <div
              className={styles.progressTrack}
              role="progressbar"
              aria-valuenow={Math.round(progress * 100)}
              aria-valuemin={0}
              aria-valuemax={100}
              aria-label={t('used')}
            >
              <div className={styles.progressFill} style={{ width: `${Math.max(progress * 100, 2)}%` }} />
            </div>
          )}

          <div className={styles.breakdown}>
            {showGranted && granted != null && (
              <BreakdownChip
                icon="sparkles"
                label={t(providerKind === 'moonshot' ? 'voucher' : 'granted')}
                value={formatAmount(currency, granted)}
              />
            )}
            {showTopUp && topUp != null && (
              <BreakdownChip
                icon={isMoonshotOwing ? 'warning' : 'down'}
                label={t(providerKind === 'moonshot' ? 'cash' : 'topUp')}
                value={formatAmount(currency, topUp)}
                isWarning={isMoonshotOwing}
                warningLabel={isMoonshotOwing ? t('owing') : undefined}
              />
            )}
            {showUsage && totalUsage != null && (
              <BreakdownChip
                icon="up"
                label={t('used')}
                value={formatAmount(currency, totalUsage)}
              />
            )}
          </div>
        </div>
      )}
    </>
  );
}

type BreakdownIcon = 'sparkles' | 'down' | 'up' | 'warning';

function BreakdownIconRender({ icon, isWarning }: { icon: BreakdownIcon; isWarning: boolean }) {
  const props = { size: 12, strokeWidth: 2.2, 'aria-hidden': true } as const;
  switch (icon) {
    case 'sparkles':
      return <Sparkles {...props} />;
    case 'down':
      return <ArrowDownCircle {...props} />;
    case 'up':
      return <ArrowUpCircle {...props} />;
    case 'warning':
      return <AlertTriangle {...props} />;
  }
}

function BreakdownChip({
  icon,
  label,
  value,
  isWarning = false,
  warningLabel,
}: {
  icon: BreakdownIcon;
  label: string;
  value: string;
  isWarning?: boolean;
  warningLabel?: string;
}) {
  return (
    <div className={styles.breakdownItem}>
      <div className={styles.breakdownIconChip} data-warning={isWarning ? 'true' : 'false'}>
        <BreakdownIconRender icon={icon} isWarning={isWarning} />
      </div>
      <div className={styles.breakdownTextCol}>
        <div className={styles.breakdownLabel}>{label}</div>
        <div className={styles.breakdownValueRow}>
          <span className={isWarning ? styles.breakdownValueWarning : styles.breakdownValue}>
            {value}
          </span>
          {warningLabel && <span className={styles.owingTag}>{warningLabel}</span>}
        </div>
      </div>
    </div>
  );
}

function SkeletonContent() {
  return (
    <div className={styles.skeletonGroup} aria-hidden="true">
      <div className={styles.skeletonAmount} />
      <div className={styles.skeletonBar} />
      <div className={styles.skeletonChips}>
        <div className={styles.skeletonChip} />
        <div className={styles.skeletonChip} />
      </div>
    </div>
  );
}

function ErrorContent({
  isKeyInvalid,
  message,
  onRetry,
  t,
}: {
  isKeyInvalid: boolean;
  message: string;
  onRetry: () => void;
  t: ReturnType<typeof useTranslations>;
}) {
  if (isKeyInvalid) {
    return (
      <div className={styles.errorBlock}>
        <div className={styles.errorTitle}>{message}</div>
      </div>
    );
  }
  return (
    <div className={styles.errorRow}>
      <span className={styles.errorText}>{message}</span>
      <button type="button" className={styles.retryChip} onClick={onRetry}>
        <RefreshCw size={11} strokeWidth={2.4} aria-hidden="true" />
        <span>{t('retry')}</span>
      </button>
    </div>
  );
}
