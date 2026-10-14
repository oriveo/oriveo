'use client';

import { useTranslations } from 'next-intl';
import { WarningIcon } from '@phosphor-icons/react';
import type { RelayRequestedConfig } from '@oriveo/shared';
import { Button } from '@oriveo/ui';
import type { ProviderErrorKind } from '@oriveo/core/providers/errors';
import { localizeProviderError } from '../../../../lib/core/providers/error-i18n';
import {
  extractPingErrorMessage,
  extractRelayPingFailureDetails,
} from '../../../../lib/core/providers/ping-relay';
import styles from '../ProviderDetail.module.css';

/** Every error kind has `errors.<kind>.title / .message`; an exhaustive table makes the compiler fail when a new kind is added without them. */
const PROVIDER_ERROR_KINDS: Record<ProviderErrorKind, true> = {
  invalidKey: true,
  unauthorized: true,
  badRequest: true,
  quotaExceeded: true,
  rateLimited: true,
  unavailable: true,
  network: true,
  emptyResponse: true,
  upstream: true,
  emptyModelCatalog: true,
  grokSubscriptionUnavailable: true,
  grokSubscriptionIneligible: true,
  grokSubscriptionExpired: true,
  grokSubscriptionQuotaExhausted: true,
  openAISubscriptionUnavailable: true,
  openAISubscriptionIneligible: true,
  openAISubscriptionExpired: true,
  openAISubscriptionQuotaExhausted: true,
};

/**
 * Title = error kind title; body = relay guidance or the localized guidance for that kind; upstream original text goes only into technical details.
 * Not a ProviderError (local exceptions etc.): returns null and takes the old path.
 */
function relayFailureCopy(error: unknown): { kind: ProviderErrorKind; guidance: string | null } | null {
  if (!error || typeof error !== 'object' || error instanceof Error) return null;
  const value = error as { kind?: unknown; message?: unknown; relayGuidance?: unknown; relayHTMLPage?: unknown };
  if (typeof value.kind !== 'string' || !Object.prototype.hasOwnProperty.call(PROVIDER_ERROR_KINDS, value.kind)) return null;
  // The guidance sentences and "came back as a web page" are our own English source sentences, localized by source sentence; other messages are upstream original text.
  const ownSentence = (value.relayGuidance === true || value.relayHTMLPage === true) && typeof value.message === 'string';
  return { kind: value.kind as ProviderErrorKind, guidance: ownSentence ? (value.message as string) : null };
}

/**
 * Verification failure card (shared by edit connection / replace key on the detail page / manual setup in the add flow): icon + [title; reason] → primary button → collapsible "Technical details".
 * Reason and details emit text only through the redaction list (keys, header values, query parameter values, custom User-Agent).
 */
export function RelaySettingsFailureCard({
  error,
  canSaveUnverified,
  apiKey,
  connectionKeySecrets,
  relayRequested,
  showRetry,
  notSavedNote,
  localError = false,
  onRetry,
  onSaveUnverified,
  onDismiss,
}: {
  error: unknown;
  canSaveUnverified: boolean;
  apiKey: string;
  /** All keys of this connection; only goes into the local redaction list. */
  connectionKeySecrets: readonly string[];
  relayRequested: RelayRequestedConfig;
  showRetry: boolean;
  /** After the reason, a separate line "The connection has not been saved" (manual setup in the add flow). */
  notSavedNote?: string;
  /** Local error (e.g. persistence exception): technical details show only the exception detail itself, without the "Upstream response" subheading and redaction note. */
  localError?: boolean;
  onRetry: () => void;
  onSaveUnverified: () => void;
  /** Edit connection: when unverified saves are not allowed, the primary button = close, clearing the failure state (as in iOS RelayEditView). */
  onDismiss?: () => void;
}) {
  const tr = useTranslations('pages.relayDetail');
  const tSetup = useTranslations('pages.relaySetup');
  const te = useTranslations('errors');
  const tc = useTranslations('common');
  const dismissible = !showRetry && !canSaveUnverified && onDismiss !== undefined;
  const details = extractRelayPingFailureDetails(error, { apiKey, relayRequested, connectionKeySecrets });
  const copy = relayFailureCopy(error);
  const title = copy ? te(`${copy.kind}.title`) : tr('testRelayFailed');
  const reason = copy
    ? (copy.guidance !== null ? localizeProviderError(copy.guidance, te) : te(`${copy.kind}.message`))
    // A network failure is a ProviderErrorObject (Error subclass), and extractPingErrorMessage returns the English source sentence as is; localize it once more via the source-sentence table.
    : localizeProviderError(extractPingErrorMessage(error, te), te);
  return (
    <section className={styles.relayVerificationFailure} role="alert" data-tone="warning">
      <div className={styles.relayFailureHeadline}>
        <WarningIcon size={22} weight="fill" className={styles.relayFailureIcon} aria-hidden="true" />
        <div className={styles.relayFailureText}>
          <strong className={styles.relayFailureTitle}>{title}</strong>
          <p>{reason}</p>
          {notSavedNote ? <p data-failure-note>{notSavedNote}</p> : null}
        </div>
      </div>
      {/* Only one primary button in the card; the retry for a failed key replacement on the detail page is the only retry entry there, kept as is. Full-width primary button. */}
      {(showRetry || canSaveUnverified || dismissible) && (
        <div className={styles.relayFailureActions}>
          {showRetry && <Button tone="primary" className={styles.relayFailurePrimary} onClick={onRetry}>{tr('verifyAndSave')}</Button>}
          {canSaveUnverified && (
            <Button tone={showRetry ? 'secondary' : 'primary'} className={styles.relayFailurePrimary} onClick={onSaveUnverified}>{tr('saveUnverified')}</Button>
          )}
          {dismissible && <Button tone="primary" className={styles.relayFailurePrimary} onClick={onDismiss}>{tc('close')}</Button>}
        </div>
      )}
      {(details.requestURL || details.statusCode !== undefined || details.upstreamMessage) && (
        <details className={styles.relayFailureDetails}>
          <summary>{tSetup('attemptedRequests')}</summary>
          {details.requestURL && (
            <div className={styles.relayFailureAttempt}>
              {/* Local errors send no request: the address row shows only the address, without request method and status. */}
              {localError ? <code>{details.requestURL}</code> : <code>POST {details.requestURL}</code>}
              {!localError && <span>{details.statusCode ?? tSetup('networkStatus')}</span>}
            </div>
          )}
          {details.upstreamMessage && (
            <div className={styles.relayFailureDiagnostic}>
              {!localError && <strong>{tSetup('upstreamDiagnostic')}</strong>}
              <pre>{details.upstreamMessage}</pre>
              {!localError && <small>{tr('upstreamBodyRedacted')}</small>}
            </div>
          )}
        </details>
      )}
    </section>
  );
}
