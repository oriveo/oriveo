'use client';

/**
 * Device code authorization dialog for Grok subscription sign-in.
 *
 * The authorization page opens in a new tab instead of waiting for a callback: the device code flow has
 * no redirect at all, and the result is obtained by polling the token endpoint. The page URL is validated
 * against the delivered `trustedVerificationHosts` before opening (in the parsing layer), so the user is
 * never sent to an unknown domain.
 */

import { useEffect, useId, useRef } from 'react';
import { useTranslations } from 'next-intl';
import { UserRoundCheck } from 'lucide-react';
import { Button } from '@oriveo/ui';
import type { ProviderSubscriptionCredential } from '@oriveo/shared';
import {
  grokSubscriptionErrorAllowsRetry,
  type GrokSubscriptionAuthConfig,
  type GrokSubscriptionErrorKind,
} from '@oriveo/core/providers/grok-subscription';
import { useFocusTrap } from '../../lib/hooks/useFocusTrap';
import { useGrokDeviceAuthorization } from '../../lib/hooks/useGrokDeviceAuthorization';
import styles from './ProviderSubscription.module.css';

interface GrokSubscriptionAuthorizationDialogProps {
  config: GrokSubscriptionAuthConfig;
  onAuthorized: (credential: ProviderSubscriptionCredential) => void;
  onCancel: () => void;
}

/** Failure semantics to copy key. All four sentences must differ, because the ways out are completely opposite. */
export function grokSubscriptionErrorMessageKey(kind: GrokSubscriptionErrorKind): string {
  switch (kind) {
    case 'clientVersionRejected':
    case 'configurationUnavailable':
      return 'errorUnavailable';
    case 'subscriptionNotEligible':
      return 'errorIneligible';
    case 'unauthorized':
      return 'errorExpired';
    case 'quotaExhausted':
      return 'errorQuotaExhausted';
    case 'codeExpired':
      return 'errorCodeExpired';
    case 'accessDenied':
      return 'errorAccessDenied';
    case 'catalogUnavailable':
      return 'errorCatalogUnavailable';
    default:
      return 'errorTransport';
  }
}

export function GrokSubscriptionAuthorizationDialog({
  config,
  onAuthorized,
  onCancel,
}: GrokSubscriptionAuthorizationDialogProps) {
  const t = useTranslations('pages.providerSetup.grokSubscription');
  const tc = useTranslations('common');
  const dialogRef = useRef<HTMLDivElement>(null);
  const titleId = useId();
  useFocusTrap(dialogRef, true);

  const { phase, didOpenVerificationPage, start, cancel, markVerificationPageOpened } =
    useGrokDeviceAuthorization(config);

  useEffect(() => {
    start();
    // Fired once on mount; retries are triggered explicitly by the button in the failure state.
  }, []);

  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault();
        cancel();
        onCancel();
      }
    };
    document.addEventListener('keydown', handler);
    return () => document.removeEventListener('keydown', handler);
  }, [cancel, onCancel]);

  useEffect(() => {
    // Hand the credential to the caller for persistence and provider registration immediately, without
    // holding another frame here: the user already pressed Approve in the browser, so making them come
    // back and press Done is redundant.
    if (phase.kind === 'succeeded') onAuthorized(phase.credential);
  }, [phase, onAuthorized]);

  return (
    <div
      className={styles.overlay}
      onClick={() => {
        cancel();
        onCancel();
      }}
    >
      <div
        ref={dialogRef}
        className={styles.dialog}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        data-testid="grok-subscription-dialog"
        onClick={(event) => event.stopPropagation()}
      >
        <span className={styles.dialogIcon} aria-hidden="true">
          <UserRoundCheck size={36} strokeWidth={2} />
        </span>
        <div id={titleId} className={styles.dialogTitle}>
          {t('dialogTitle')}
        </div>
        <p className={styles.dialogSubtitle}>{t('dialogSubtitle')}</p>

        <div className={styles.dialogBody}>
          {(phase.kind === 'idle' || phase.kind === 'requesting' || phase.kind === 'succeeded') && (
            <div className={styles.busy}>
              <span className={styles.spinner} aria-label={tc('loading')} />
            </div>
          )}

          {phase.kind === 'awaitingAuthorization' && (
            <>
              <div className={styles.codeBox}>
                <span className={styles.codeLabel}>{t('yourCode')}</span>
                {/* The authorization page usually already carries the short code; showing it here lets the
                    user check that the codes match, which is what proves it is the same request. */}
                <span className={styles.codeValue} data-testid="grok-subscription-user-code">
                  {phase.authorization.userCode}
                </span>
              </div>
              <Button
                tone="primary"
                onClick={() => {
                  markVerificationPageOpened();
                  window.open(phase.authorization.verificationURL, '_blank', 'noopener,noreferrer');
                }}
              >
                {didOpenVerificationPage ? t('openAuthorizationPageAgain') : t('openAuthorizationPage')}
              </Button>
              {didOpenVerificationPage && (
                <div className={styles.waiting}>
                  <span className={styles.spinner} aria-hidden="true" />
                  {t('waiting')}
                </div>
              )}
            </>
          )}

          {phase.kind === 'failed' && (
            <div className={styles.actions}>
              <p className={styles.errorText} role="alert" data-testid="grok-subscription-error">
                {t(grokSubscriptionErrorMessageKey(phase.error))}
              </p>
              {/* Only failures where retrying could actually succeed get a retry button: an unsupported tier
                  is a dead end, and a button there just invites pointless clicking. */}
              {grokSubscriptionErrorAllowsRetry(phase.error) && (
                <Button tone="primary" onClick={start} data-testid="grok-subscription-retry">
                  {t('tryAgain')}
                </Button>
              )}
            </div>
          )}
        </div>

        <Button
          tone="secondary"
          onClick={() => {
            cancel();
            onCancel();
          }}
        >
          {tc('cancel')}
        </Button>
      </div>
    </div>
  );
}
