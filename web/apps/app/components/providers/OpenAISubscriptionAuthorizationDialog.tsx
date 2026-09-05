'use client';

/**
 * Device code authorization dialog for Codex (ChatGPT subscription sign-in).
 *
 * The authorization page opens in a new tab rather than waiting for a callback: the device code flow
 * has no redirect at all, and the result arrives by polling. The page URL comes from the config and
 * has already been checked against `trustedVerificationHosts` in the parsing layer, so the user is
 * never sent to an unknown domain.
 *
 * This is written separately from the Grok dialog rather than made generic: the two chains differ in
 * config type, error enum and hook, and forcing one generic version would make it unreadable which
 * chain took which branch. The layout shares the same CSS module.
 */

import { useEffect, useId, useRef } from 'react';
import { useTranslations } from 'next-intl';
import { UserRoundCheck } from 'lucide-react';
import { Button } from '@oriveo/ui';
import type { ProviderSubscriptionCredential } from '@oriveo/shared';
import {
  openAISubscriptionErrorAllowsRetry,
  type OpenAISubscriptionAuthConfig,
  type OpenAISubscriptionErrorKind,
} from '@oriveo/core/providers/openai-subscription';
import { useFocusTrap } from '../../lib/hooks/useFocusTrap';
import { useOpenAIDeviceAuthorization } from '../../lib/hooks/useOpenAIDeviceAuthorization';
import styles from './ProviderSubscription.module.css';

interface OpenAISubscriptionAuthorizationDialogProps {
  config: OpenAISubscriptionAuthConfig;
  onAuthorized: (credential: ProviderSubscriptionCredential) => void;
  onCancel: () => void;
}

/** Failure semantics -> copy key. All four sentences must differ, because the recovery actions are opposites. */
export function openAISubscriptionErrorMessageKey(kind: OpenAISubscriptionErrorKind): string {
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

export function OpenAISubscriptionAuthorizationDialog({
  config,
  onAuthorized,
  onCancel,
}: OpenAISubscriptionAuthorizationDialogProps) {
  const t = useTranslations('pages.providerSetup.openaiSubscription');
  const tc = useTranslations('common');
  const dialogRef = useRef<HTMLDivElement>(null);
  const titleId = useId();
  useFocusTrap(dialogRef, true);

  const { phase, didOpenVerificationPage, start, cancel, markVerificationPageOpened } =
    useOpenAIDeviceAuthorization(config);

  useEffect(() => {
    start();
    // Start once on mount; retries are triggered explicitly by the button in the failed state.
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
    // Hand the credential to the caller immediately so it can be stored and the provider registered,
    // without lingering another frame here - the user has already clicked approve in the browser, and
    // making them come back and press "done" is redundant.
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
        data-testid="openai-subscription-dialog"
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
                {/* The Codex authorization page does **not** carry the short code (there is no
                     verification_uri_complete), so the user has to read it from here and type it in.
                     This code is a required step in the flow, not decoration for cross-checking. */}
                <span className={styles.codeValue} data-testid="openai-subscription-user-code">
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
              <p className={styles.errorText} role="alert" data-testid="openai-subscription-error">
                {/* "Upstream returned something we did not expect" and "the network is down" are two
                      different things. They used to share one "cannot reach Codex" sentence, which made
                      user reports useless for diagnosis. With the status code attached, this class of
                      failure can finally describe itself. */}
                {phase.error === 'upstream' && phase.upstreamStatus
                  ? t('errorUpstream', { status: phase.upstreamStatus })
                  : t(openAISubscriptionErrorMessageKey(phase.error))}
              </p>
              {/* Only failures where a retry can actually succeed get a retry button: an unsupported
                    tier is a dead end, and a button there only makes the user click it in vain. */}
              {openAISubscriptionErrorAllowsRetry(phase.error) && (
                <Button tone="primary" onClick={start} data-testid="openai-subscription-retry">
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
