'use client';

/**
 * Credential card for a subscription instance: shows how the connection was made, explains
 * the kill switch, and offers two ways out - reauthorize, or switch back to an API key.
 *
 * When the kill switch is off, connected instances are not removed: the card goes read-only
 * and shows the delivered explanation (falling back to local copy), letting the user switch
 * back to an API key or delete it themselves. It never fails silently.
 *
 * Both subscription paths (Grok and Codex) share this card: the three states have exactly
 * the same shape and differ only in the copy namespace and the testId prefix. The card does
 * not know about provider kinds - compute availability and pass it in.
 */

import { useTranslations } from 'next-intl';
import { UserRoundCheck } from 'lucide-react';
import { Button } from '@oriveo/ui';
import styles from '../ProviderDetail.module.css';
import subscriptionStyles from '../../../../components/providers/ProviderSubscription.module.css';

/** Same shape as each path's `*SubscriptionAvailability`; the card only cares about the three states and the delivered explanation. */
export type SubscriptionCardAvailability =
  | { state: 'available' }
  | { state: 'disabled'; notice?: string }
  | { state: 'unavailable' };

interface ProviderSubscriptionCardProps {
  availability: SubscriptionCardAvailability;
  onReauthorize: () => void;
  onSwitchToApiKey: () => void;
  /** next-intl namespace, for example `pages.providerDetail.grokSubscription`. */
  namespace: string;
  /** testId prefix, for example `grok` giving `grok-subscription-card`. */
  testIdPrefix: string;
}

export function ProviderSubscriptionCard({
  availability,
  onReauthorize,
  onSwitchToApiKey,
  namespace,
  testIdPrefix,
}: ProviderSubscriptionCardProps) {
  const t = useTranslations(namespace);
  const disabledNotice =
    availability.state === 'disabled' ? (availability.notice ?? t('disabledFallback')) : null;
  // `unavailable` (the backend delivered no configuration for it) also cannot reauthorize: with no endpoint the flow would stall halfway.
  const canReauthorize = availability.state === 'available';

  return (
    <div className={styles.section} data-testid={`${testIdPrefix}-subscription-card`}>
      <div className={styles.sectionLabel}>{t('sectionTitle')}</div>
      <div className={subscriptionStyles.connectPanel}>
        <div className={subscriptionStyles.modeOption} style={{ cursor: 'default' }}>
          <span className={subscriptionStyles.modeIcon} aria-hidden="true">
            <UserRoundCheck size={16} strokeWidth={2.2} />
          </span>
          <span className={subscriptionStyles.modeCopy}>
            <span className={subscriptionStyles.modeOptionTitle}>{t('connectedTitle')}</span>
            <span className={subscriptionStyles.modeOptionDesc}>{t('connectedDescription')}</span>
          </span>
        </div>

        {disabledNotice && (
          <p
            className={subscriptionStyles.disabledNotice}
            role="status"
            data-testid={`${testIdPrefix}-subscription-disabled-notice`}
          >
            {disabledNotice}
          </p>
        )}

        <div className={subscriptionStyles.actions}>
          {canReauthorize && (
            <Button
              tone="secondary"
              size="sm"
              onClick={onReauthorize}
              data-testid={`${testIdPrefix}-subscription-reauthorize`}
            >
              {t('reauthorize')}
            </Button>
          )}
          <Button
            tone="secondary"
            size="sm"
            onClick={onSwitchToApiKey}
            data-testid={`${testIdPrefix}-subscription-switch-api-key`}
          >
            {t('switchToApiKey')}
          </Button>
        </div>
      </div>
    </div>
  );
}
