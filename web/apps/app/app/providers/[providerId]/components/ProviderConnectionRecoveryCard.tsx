'use client';

import { useTranslations } from 'next-intl';
import { AlertTriangle, Globe, KeyRound, RefreshCw, UserRoundCheck, X } from 'lucide-react';
import type { Provider } from '@oriveo/shared';
import { getEffectiveStatusKind } from '../../../../lib/core/providers/provider-status';
import styles from './ProviderConnectionRecoveryCard.module.css';

interface ProviderConnectionRecoveryCardProps {
  provider: Provider;
  onEditApiKey: () => void;
  onRetryConnection: () => void;
  /** Pass undefined when there is no endpoint option, as with relay, and the button hides itself */
  onCheckEndpoint?: () => void;
  /** Label for the Check Endpoint button, e.g. "Base URL" or "Endpoint" */
  checkEndpointLabel?: string;
  onDismiss: () => void;
  /** Localised error detail, already mapped through errors.*. Rendered only in connection-issue mode, not in missing-key mode. */
  localizedLastError?: string;
  disabled?: boolean;
}

/**
 * Recovery card on the detail page for a connection issue or a missing key.
 * - Two wordings: needsKey versus the real error text
 * - Primary action Edit API Key (solid yellow), optional secondary Check Endpoint, plus Retry
 * - A dismiss button
 */
export function ProviderConnectionRecoveryCard({
  provider,
  onEditApiKey,
  onRetryConnection,
  onCheckEndpoint,
  checkEndpointLabel,
  onDismiss,
  localizedLastError,
  disabled = false,
}: ProviderConnectionRecoveryCardProps) {
  const t = useTranslations('pages.providerDetail.recoveryCard');

  const effectiveKind = getEffectiveStatusKind(provider);
  const needsKeyOnThisDevice = effectiveKind === 'needsKey';
  // A subscription link has no key to fill in, so both the wording and the primary action change:
  // telling the user to add an API key is an instruction they can never follow, while the action
  // that actually fixes it is running the authorisation again.
  const isSubscription = provider.authMode === 'subscription';

  const headlineText = isSubscription
    ? (needsKeyOnThisDevice ? t('subscriptionNeedsAuthHeadline') : t('subscriptionIssueHeadline'))
    : (needsKeyOnThisDevice ? t('needsKeyHeadline') : t('connectionIssueHeadline'));

  return (
    <section className={styles.card} role="status">
      <div className={styles.row}>
        <span className={styles.iconBubble} aria-hidden="true">
          {isSubscription && needsKeyOnThisDevice ? (
            <UserRoundCheck size={14} strokeWidth={2.6} />
          ) : needsKeyOnThisDevice ? (
            <KeyRound size={14} strokeWidth={2.6} />
          ) : (
            <AlertTriangle size={14} strokeWidth={2.4} />
          )}
        </span>

        <div className={styles.copyStack}>
          <p className={styles.headline}>{headlineText}</p>
          {!needsKeyOnThisDevice && localizedLastError && (
            <p className={styles.detail}>{localizedLastError}</p>
          )}
        </div>

        <button
          type="button"
          className={styles.dismissBtn}
          onClick={onDismiss}
          aria-label={t('dismiss')}
          disabled={disabled}
        >
          <X size={12} strokeWidth={2.6} aria-hidden="true" />
        </button>
      </div>

      <div className={styles.actions}>
        <button
          type="button"
          className={styles.primaryAction}
          onClick={onEditApiKey}
          disabled={disabled}
          data-testid={isSubscription ? 'recovery-reauthorize' : 'recovery-edit-api-key'}
        >
          {isSubscription
            ? <UserRoundCheck size={13} strokeWidth={2.4} aria-hidden="true" />
            : <KeyRound size={13} strokeWidth={2.4} aria-hidden="true" />}
          <span>{isSubscription ? t('reauthorize') : t('editApiKey')}</span>
        </button>

        {onCheckEndpoint && checkEndpointLabel && (
          <button type="button" className={styles.secondaryAction} onClick={onCheckEndpoint} disabled={disabled}>
            <Globe size={13} strokeWidth={2.4} aria-hidden="true" />
            <span>{checkEndpointLabel}</span>
          </button>
        )}

        <button type="button" className={styles.secondaryAction} onClick={onRetryConnection} disabled={disabled}>
          <RefreshCw size={13} strokeWidth={2.4} aria-hidden="true" />
          <span>{t('retry')}</span>
        </button>
      </div>
    </section>
  );
}
