'use client';

import { useTranslations } from 'next-intl';
import { modelControlTransportLabel } from '../../../../lib/core/chat/model-control-capability-layout';
import type { RelayDiscoveryResult } from '../../../../lib/core/providers/probe/probe-runner';
import styles from './RelaySetup.module.css';

/** Discovery / verification result card with the "attempted requests" list, shared by the step 1 detection card and the step 2 save failure (the old manual two-page flow is gone). */
export function DiscoveryStatus({ result }: { result: RelayDiscoveryResult | null }) {
  const t = useTranslations('pages.relaySetup');
  if (!result) return null;
  const transport = result.detection ? transportLabel(result.detection.transport) : '';
  const success = result.state !== 'failed';
  const description = result.state === 'verified'
    ? t('verifiedProtocol', { protocol: transport })
    : result.state === 'needs_manual_model' && result.detection?.detectionEvidence === 'generation_probe'
      ? t('probeProtocol')
      : result.state === 'needs_manual_model'
        ? t('emptyCatalog')
        : t(failureMessageKey(result.failure));

  return (
    <section className={styles.statusCard} data-state={success ? 'success' : 'error'} role="status">
      <p>{description}</p>
      {result.detection?.modelIDs.length ? (
        <p>{t('modelsFound', { count: result.detection.modelIDs.length })}</p>
      ) : null}
      {result.retriedRequestCount > 0 ? (
        <p>{t('automaticRetries', { count: result.retriedRequestCount })}</p>
      ) : null}
      {result.state === 'needs_manual_model' && result.diagnostic ? (
        <div className={styles.upstreamDiagnostic}>
          <strong>{t('upstreamDiagnostic')}</strong>
          <pre>{result.diagnostic}</pre>
        </div>
      ) : null}
      {result.state === 'failed' ? <RelayDiscoveryDetails result={result} /> : null}
    </section>
  );
}

/** The "attempted requests" list and the upstream's own words below a failure (shared by the step 1 detection card and step 2). */
export function RelayDiscoveryDetails({ result }: { result: RelayDiscoveryResult }) {
  const t = useTranslations('pages.relaySetup');
  if (result.attempts.length > 0) {
    return (
      <details className={styles.technicalDetails}>
        <summary>{t('attemptedRequests')}</summary>
        <ul>
          {result.attempts.map((attempt, index) => (
            <li key={`${attempt.method}-${attempt.requestURL}-${index}`}>
              <code>{attempt.method} {attempt.requestURL}</code>
              <span>{attempt.statusCode ?? t('networkStatus')}</span>
            </li>
          ))}
        </ul>
        {result.diagnostic ? (
          <div className={styles.upstreamDiagnostic}>
            <strong>{t('upstreamDiagnostic')}</strong>
            <pre>{result.diagnostic}</pre>
          </div>
        ) : null}
      </details>
    );
  }
  if (!result.diagnostic) return null;
  return (
    <div className={styles.upstreamDiagnostic}>
      <strong>{t('upstreamDiagnostic')}</strong>
      <pre>{result.diagnostic}</pre>
    </div>
  );
}

export function failureMessageKey(failure: RelayDiscoveryResult['failure']): string {
  switch (failure) {
    case 'embedded_query': return 'embeddedQuery';
    case 'authentication_rejected': return 'authenticationRejected';
    case 'rate_limited': return 'relayRateLimited';
    case 'temporary_failure': return 'temporaryFailure';
    case 'network': return 'networkFailure';
    case 'invalid_response': return 'invalidResponse';
    case 'generation_not_verified': return 'noProtocolVerified';
    case 'invalid_endpoint': return 'invalidRequestURL';
    case 'route_unavailable':
    default:
      return 'routeUnavailable';
  }
}

/** Protocol proper names are not translated (same table as the default-protocol row of the edit-connection page). */
function transportLabel(transport: NonNullable<RelayDiscoveryResult['detection']>['transport']): string {
  return modelControlTransportLabel(transport) ?? transport;
}
