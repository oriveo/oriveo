'use client';

import { useEffect, useRef } from 'react';
import { ChevronDown, Eye, EyeOff, Loader2, Radar, Save } from 'lucide-react';
import { useTranslations } from 'next-intl';
import { Button } from '@oriveo/ui';
import type { RelayKind, RelayRequestedConfig } from '@oriveo/shared';
import { relayFormFieldDefinition } from '@oriveo/core/providers/relay-form-validation';
import { RelayKindPicker } from '../../../../components/providers/RelayKindPicker';
import { getApiKeyInputProps } from '../../../../lib/forms/api-key-input-props';
import type { RelayDiscoveryResult } from '../../../../lib/core/providers/probe/probe-runner';
import styles from './RelaySetup.module.css';

/** The placeholders are example literals from the shared form definition and are not localized; both flows read the same source. */
const ENDPOINT_PLACEHOLDER = relayFormFieldDefinition('endpoint')?.placeholder ?? '';
const API_KEY_PLACEHOLDER = relayFormFieldDefinition('api_key')?.placeholder ?? '';

export interface RelaySimpleFormValues {
  name: string;
  endpoint: string;
  apiKey: string;
  defaultModel: string;
}

interface RelaySimpleFormProps {
  values: RelaySimpleFormValues;
  onChange: (patch: Partial<RelaySimpleFormValues>) => void;
  errors: { endpoint?: string; apiKey?: string };
  requiresCredential: boolean;
  endpointNormalizationVersion: number;
  showKey: boolean;
  onToggleKey: () => void;
  /**
   * The shared validation function decides whether this form can be submitted. Whether the
   * credential is required and whether the address can be normalized are both resolved there, so
   * this component does not check "is the input empty" itself.
   */
  canSubmit: boolean;
  defaultModelPlaceholder: string;
  manualMode: boolean;
  onToggleManual: () => void;
  relayKind: RelayKind;
  onRelayKindChange: (kind: RelayKind) => void;
  customRequested: RelayRequestedConfig;
  onCustomRequestedChange: (patch: Partial<RelayRequestedConfig>) => void;
  result: RelayDiscoveryResult | null;
  isDetecting: boolean;
  onPrimaryAction: () => void;
}

export function RelaySimpleForm({
  values,
  onChange,
  errors,
  requiresCredential,
  endpointNormalizationVersion,
  showKey,
  onToggleKey,
  canSubmit,
  defaultModelPlaceholder,
  manualMode,
  onToggleManual,
  relayKind,
  onRelayKindChange,
  result,
  isDetecting,
  onPrimaryAction,
}: RelaySimpleFormProps) {
  const t = useTranslations('pages.relaySetup');
  const td = useTranslations('pages.providerDetail');
  const endpointInputRef = useRef<HTMLInputElement>(null);
  useEffect(() => {
    if (endpointNormalizationVersion <= 0) return;
    endpointInputRef.current?.focus();
    endpointInputRef.current?.select();
  }, [endpointNormalizationVersion]);
  const catalogModelIDs = result?.detection?.modelIDs ?? [];
  const currentModelID = values.defaultModel.trim();
  const selectableModelIDs = currentModelID && !catalogModelIDs.includes(currentModelID)
    ? [currentModelID, ...catalogModelIDs]
    : catalogModelIDs;
  const actionKey = result?.state === 'verified'
    ? 'connectAndSave'
    : result?.state === 'needs_manual_model'
      ? 'saveAndContinue'
      : 'detectConnectionSettings';
  const ActionIcon = result?.state === 'verified' || result?.state === 'needs_manual_model'
    ? Save
    : Radar;

  return (
    <div className={styles.form}>
      <div className={styles.field}>
        <label htmlFor="relay-request-url">{t('requestURLLabel')}</label>
        <input
          ref={endpointInputRef}
          id="relay-request-url"
          className={styles.input}
          type="url"
          value={values.endpoint}
          placeholder={ENDPOINT_PLACEHOLDER}
          onChange={(event) => onChange({ endpoint: event.target.value })}
          autoComplete="url"
          spellCheck={false}
          autoFocus
        />
        <small>{t('requestURLFootnote')}</small>
        {errors.endpoint ? <span className={styles.fieldError}>{errors.endpoint}</span> : null}
      </div>

      {requiresCredential ? <div className={styles.field}>
        <label htmlFor="relay-api-key">{t('apiKeyLabel')}</label>
        <div className={styles.keyShell}>
          <input
            id="relay-api-key"
            className={styles.keyInput}
            value={values.apiKey}
            placeholder={API_KEY_PLACEHOLDER}
            onChange={(event) => onChange({ apiKey: event.target.value })}
            {...getApiKeyInputProps('relay-api-key', showKey ? 'visible' : 'masked')}
          />
          <button
            type="button"
            className={styles.iconButton}
            onClick={onToggleKey}
            aria-label={showKey ? td('hideKey') : td('showKey')}
          >
            {showKey ? <EyeOff size={18} /> : <Eye size={18} />}
          </button>
        </div>
        <small>{t('apiKeyPrivacy')}</small>
        {errors.apiKey ? <span className={styles.fieldError}>{errors.apiKey}</span> : null}
      </div> : (
        <div className={styles.noCredentialRow}>{t('localNoCredentials')}</div>
      )}

      <div className={styles.field}>
        <label htmlFor="relay-default-model">{t('defaultModelLabel')}</label>
        {catalogModelIDs.length > 0 ? (
          <select
            id="relay-default-model"
            className={styles.input}
            value={values.defaultModel}
            onChange={(event) => onChange({ defaultModel: event.target.value })}
          >
            {selectableModelIDs.map((modelID) => <option key={modelID} value={modelID}>{modelID}</option>)}
          </select>
        ) : (
          <input
            id="relay-default-model"
            className={styles.input}
            value={values.defaultModel}
            placeholder={defaultModelPlaceholder}
            onChange={(event) => onChange({ defaultModel: event.target.value })}
            autoComplete="off"
            spellCheck={false}
          />
        )}
        <small>{t('defaultModelRecommendedFootnote')}</small>
      </div>

      {manualMode ? (
        <div className={styles.manualPanel}>
          <div className={styles.manualHeading}>
            <strong>{t('manualSetup')}</strong>
            <span>{t('manualSetupSubtitle')}</span>
          </div>
          <RelayKindPicker
            selectedKind={relayKind}
            onSelect={onRelayKindChange}
            includeCustom={false}
          />
          <div className={styles.field}>
            <label htmlFor="relay-name">{t('nameLabel')}</label>
            <input
              id="relay-name"
              className={styles.input}
              value={values.name}
              placeholder={t('namePlaceholder')}
              onChange={(event) => onChange({ name: event.target.value })}
              autoComplete="off"
            />
          </div>
        </div>
      ) : null}

      <DiscoveryStatus result={result} />

      <div className={styles.actionBar}>
        <Button
          className={styles.primaryAction}
          onClick={onPrimaryAction}
          disabled={isDetecting || !canSubmit}
        >
          {isDetecting ? <Loader2 className={styles.spinner} size={18} /> : <ActionIcon size={18} />}
          <span>{isDetecting ? t('testingRelay') : t(actionKey)}</span>
        </Button>
      </div>

      <button type="button" className={styles.manualToggle} onClick={onToggleManual}>
        <span>
          <strong>{manualMode ? t('quickTitle') : t('manualSetup')}</strong>
          <small>{manualMode ? t('quickSubtitle') : t('manualSetupSubtitle')}</small>
        </span>
        <ChevronDown size={18} data-open={manualMode} />
      </button>
    </div>
  );
}

function DiscoveryStatus({ result }: { result: RelayDiscoveryResult | null }) {
  const t = useTranslations('pages.relaySetup');
  if (!result) return null;
  const transport = result.detection ? transportLabel(result.detection.transport, t) : '';
  const success = result.state !== 'failed';
  const description = result.state === 'verified'
    ? t('verifiedProtocol', { protocol: transport })
    : result.state === 'needs_manual_model' && result.detection?.detectionEvidence === 'generation_probe'
      ? t('probeProtocol', { protocol: transport })
      : result.state === 'needs_manual_model'
        ? t('emptyCatalog')
        : t(failureMessageKey(result.failure));

  return (
    <section className={styles.statusCard} data-state={success ? 'success' : 'error'} role="status">
      <strong>{success ? t('relayDetected') : t('relayDetectionFailed')}</strong>
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
      {result.state === 'failed' && result.attempts.length > 0 ? (
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
      ) : null}
      {result.state === 'failed' && result.attempts.length === 0 && result.diagnostic ? (
        <div className={styles.upstreamDiagnostic}>
          <strong>{t('upstreamDiagnostic')}</strong>
          <pre>{result.diagnostic}</pre>
        </div>
      ) : null}
    </section>
  );
}

function failureMessageKey(failure: RelayDiscoveryResult['failure']): string {
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

function transportLabel(
  transport: NonNullable<RelayDiscoveryResult['detection']>['transport'],
  t: (key: string) => string,
): string {
  switch (transport) {
    case 'openai_chat_completions': return t('kind.openai.title');
    case 'openai_responses': return t('kind.codex.title');
    case 'anthropic_messages': return t('kind.anthropic.title');
    case 'gemini_generate_content': return t('kind.gemini.title');
  }
}
