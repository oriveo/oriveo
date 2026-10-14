'use client';

import { useEffect, useRef, useState } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import {
  ArrowElbowDownRight,
  CheckCircle,
  Circle,
  CircleNotch,
  Eye,
  Info,
  Key,
  Link,
  MinusCircle,
  Plus,
  SlidersHorizontal,
  Trash,
  WarningCircle,
} from '@phosphor-icons/react';
import { Button } from '@oriveo/ui';
import { relayFormFieldDefinition } from '@oriveo/core/providers/relay-form-validation';
import { getApiKeyInputProps } from '../../../../lib/forms/api-key-input-props';
import { previewAPIRoot } from '../../../../lib/core/providers/probe/endpoint-normalizer';
import type { RelayDiscoveryResult } from '../../../../lib/core/providers/probe/probe-runner';
import styles from './RelaySetup.module.css';
import { RELAY_SETUP_SECONDARY_KEY } from './setup-board';
import { ENDPOINT_SLOT_PLACEHOLDER, endpointFromSlotInput, endpointSchemeChip, endpointSlotText } from './setup-board-parts';
import {
  RELAY_CHECK_IDS,
  RELAY_SECURITY_MODE,
  formatRelayCheckSeconds,
  relayCheckElapsedMs,
  relayDetectionProgress,
  relayShowsKeyNames,
  type RelayCheckID,
  type RelayKeyDraft,
  type RelayStepOneDetection,
} from './relay-setup-two-step';

const API_KEY_PLACEHOLDER = relayFormFieldDefinition('api_key')?.placeholder ?? '';
const CHECK_LABEL_KEYS: Record<RelayCheckID, string> = {
  connection: 'twoStep.checkConnection',
  catalog: 'twoStep.checkCatalog',
  protocols: 'twoStep.checkProtocols',
};

interface RelaySetupStepOneProps {
  endpoint: string;
  onEndpointChange: (value: string) => void;
  endpointNormalizationVersion: number;
  keys: RelayKeyDraft[];
  onKeyChange: (index: number, patch: Partial<Pick<RelayKeyDraft, 'apiKey' | 'name'>>) => void;
  onAddKey: () => void;
  onRemoveKey: (index: number) => void;
  errors: { endpoint?: string; apiKey?: string };
  showKey: boolean;
  onToggleKey: () => void;
  detection: RelayStepOneDetection | null;
  isDetecting: boolean;
  primaryEnabled: boolean;
  onPrimary: () => void;
  onCancelDetection: () => void;
  onToggleManual: () => void;
}

/** Step 1 (Setup board): address + preview row -> keys (one or more) -> detection card -> Next. */
export function RelaySetupStepOne(props: RelaySetupStepOneProps) {
  const t = useTranslations('pages.relaySetup');
  const { endpointNormalizationVersion, detection } = props;
  const running = detection !== null && RELAY_CHECK_IDS.some((id) => detection.checks[id].state === 'running');

  return (
    <div className={styles.form}>
      <RelaySetupEndpointField
        endpoint={props.endpoint}
        onEndpointChange={props.onEndpointChange}
        endpointNormalizationVersion={endpointNormalizationVersion}
        previewRoot={detection?.discovery?.detection?.apiBaseURL}
        error={props.errors.endpoint}
      />

      <RelaySetupKeySlots
        keys={props.keys}
        onKeyChange={props.onKeyChange}
        onAddKey={props.onAddKey}
        onRemoveKey={props.onRemoveKey}
        showKey={props.showKey}
        onToggleKey={props.onToggleKey}
        issues={props.errors.apiKey ? [props.errors.apiKey] : []}
      />

      {detection ? <RelayDetectionChecklist detection={detection} /> : null}

      {/* Local network / CORS proxy note: full-width footnote at the end of the form. */}
      <small className={styles.formFootnote}>{t('apiKeyPrivacy')}</small>

      <div className={styles.stepFooter}>
        <span>{t('twoStep.stepOf', { current: 1, total: 2 })}</span>
        {running ? (
          <button
            type="button"
            className={styles.linkButton}
            onClick={props.onCancelDetection}
            data-testid="relay_setup_cancel_detection_button"
          >
            {t('twoStep.cancelDetection')}
          </button>
        ) : null}
      </div>
      <div className={styles.actionBar}>
        <Button
          className={styles.primaryAction}
          onClick={props.onPrimary}
          disabled={!props.primaryEnabled}
          data-testid="relay_setup_next_button"
        >
          {props.isDetecting ? <CircleNotch className={styles.spinner} size={18} data-spinner aria-hidden="true" /> : null}
          <span>{t('twoStep.next')}</span>
        </Button>
      </div>

      <button type="button" className={styles.manualToggle} onClick={props.onToggleManual}>
        <SlidersHorizontal size={18} aria-hidden="true" />
        <span>{t(RELAY_SETUP_SECONDARY_KEY)}</span>
      </button>
    </div>
  );
}

/** Detection card, three items: connectivity / fetch catalog (one row per key) / identify protocol; title row `n / 3`, each item shows its status and elapsed time. */
export function RelayDetectionChecklist({ detection }: { detection: RelayStepOneDetection }) {
  const t = useTranslations('pages.relaySetup');
  const tm = useTranslations('mcp.chat');
  const locale = useLocale();
  const running = RELAY_CHECK_IDS.some((id) => detection.checks[id].state === 'running');
  const [now, setNow] = useState(() => Date.now());
  // The in-progress item refreshes its elapsed time every 0.1 seconds.
  useEffect(() => {
    if (!running) return undefined;
    const timer = setInterval(() => setNow(Date.now()), 100);
    return () => clearInterval(timer);
  }, [running]);
  const progress = relayDetectionProgress(detection);
  const { discovery } = detection;

  // Detail / failure text (failure text uses the warning color, placed after the raw upstream response and "technical details").
  const detail = (id: RelayCheckID) => {
    const { state } = detection.checks[id];
    if (state === 'skipped') return <span className={styles.checkDetail}>{t('twoStep.checkSkipped')}</span>;
    if (id === 'connection') {
      if (state === 'failed' && detection.connectionFailureKey) {
        return <span className={styles.checkDetail} data-tone="warning">{t(detection.connectionFailureKey)}</span>;
      }
      return state === 'done' && detection.reachablePath
        ? <span className={styles.checkDetail}>{t('twoStep.reachablePath', { path: detection.reachablePath })}</span>
        : null;
    }
    if (id === 'catalog') {
      return detection.keyRows.length === 0 && state === 'failed' && detection.catalogFailureKey
        ? <span className={styles.checkDetail} data-tone="warning">{t(detection.catalogFailureKey)}</span>
        : null;
    }
    if (state === 'running') return <span className={styles.checkDetail}>{t('twoStep.protocolsRunning')}</span>;
    return state === 'done' ? <span className={styles.checkDetail}>{t('twoStep.protocolsDone')}</span> : null;
  };

  // Key catalog row: inside the title column, below the title.
  const keyRows = (id: RelayCheckID) => (id === 'catalog' && detection.keyRows.length > 0 ? (
    <span className={styles.keyRows}>
      {detection.keyRows.map((row) => (
        <span key={row.keyID} className={styles.keyRow}>
          <span className={styles.keyChip}><Key size={13} aria-hidden="true" />{row.label}</span>
          {row.count !== undefined
            ? <span>{t('twoStep.catalogCount', { count: row.count })}</span>
            : row.failureKey ? <span data-tone="warning">{t(row.failureKey)}</span> : null}
        </span>
      ))}
    </span>
  ) : null);

  const failureResult = (id: RelayCheckID): RelayDiscoveryResult | null => {
    const { state } = detection.checks[id];
    if (state !== 'failed' || !discovery) return null;
    if (discovery.state === 'failed') return discovery;
    return id === 'catalog' ? discovery : null;
  };

  const tone = RELAY_CHECK_IDS.some((id) => detection.checks[id].state === 'failed')
    ? 'warning'
    : running ? 'progress' : 'success';

  return (
    <section className={styles.detectionCard} data-testid="relay-setup-detection" data-tone={tone} role="status">
      <div className={styles.detectionHeader}>
        <strong>{t('twoStep.detectionTitle')}</strong>
        <span className={styles.detectionSubtitle}>{t('twoStep.detectionSubtitle')}</span>
        <span className={styles.detectionProgress} data-testid="relay-setup-detection-progress">{progress} / {RELAY_CHECK_IDS.length}</span>
      </div>
      <div className={styles.detectionBar} aria-hidden="true">
        <span style={{ width: `${(progress / RELAY_CHECK_IDS.length) * 100}%` }} />
      </div>
      <ul className={styles.checkList}>
        {RELAY_CHECK_IDS.map((id) => {
          const check = detection.checks[id];
          const elapsed = relayCheckElapsedMs(check, now);
          const failed = failureResult(id);
          return (
            <li key={id} data-check={id} data-state={check.state}>
              <div className={styles.checkRow}>
                <span className={styles.checkLead} data-row-lead="top">
                  <CheckIcon state={check.state} />
                  <span className={styles.checkText}>
                    <strong>{t(CHECK_LABEL_KEYS[id])}</strong>
                    {keyRows(id)}
                    {failed ? <CheckFailureDetails result={failed} /> : null}
                    {detail(id)}
                  </span>
                </span>
                {elapsed !== null ? (
                  <span className={styles.checkTrailing} data-row-trailing>
                    <span className={styles.checkElapsed} data-elapsed>
                      {tm('detail.durationS', { value: formatRelayCheckSeconds(elapsed, locale) })}
                    </span>
                  </span>
                ) : null}
              </div>
            </li>
          );
        })}
      </ul>
      <p className={styles.detectionNote}><Info size={16} aria-hidden="true" />{t('twoStep.detectionNote')}</p>
    </section>
  );
}

/** Detection failure details: raw upstream response first, then the requests Oriveo sent (collapsed), one per line. */
function CheckFailureDetails({ result }: { result: RelayDiscoveryResult }) {
  const t = useTranslations('pages.relaySetup');
  return (
    <>
      {result.diagnostic ? (
        <span className={styles.checkUpstream}>
          <strong>{t('upstreamDiagnostic')}</strong>
          <pre>{result.diagnostic}</pre>
        </span>
      ) : null}
      {result.attempts.length > 0 ? (
        <details className={styles.checkAttempts}>
          <summary>{t('whatOriveoTried')}</summary>
          <ul>
            {result.attempts.map((attempt, index) => (
              <li key={`${attempt.method}-${attempt.requestURL}-${index}`}>
                <code>{attempt.method} {attempt.requestURL}</code>
                <span>{attempt.statusCode ?? t('networkStatus')}</span>
              </li>
            ))}
          </ul>
        </details>
      ) : null}
    </>
  );
}

function CheckIcon({ state }: { state: RelayStepOneDetection['checks'][RelayCheckID]['state'] }) {
  if (state === 'running') return <CircleNotch className={styles.spinner} size={18} aria-hidden="true" />;
  if (state === 'done') return <CheckCircle size={20} weight="duotone" className={styles.checkDone} aria-hidden="true" />;
  if (state === 'failed') return <WarningCircle size={20} weight="duotone" className={styles.checkFailed} aria-hidden="true" />;
  if (state === 'skipped') return <MinusCircle size={20} className={styles.checkMuted} aria-hidden="true" />;
  return <Circle size={20} className={styles.checkMuted} aria-hidden="true" />;
}

/** Request address block (shared by step 1 and manual setup): scheme chip + input + "will request" preview row (same preview function). */
export function RelaySetupEndpointField(props: {
  endpoint: string;
  onEndpointChange: (value: string) => void;
  endpointNormalizationVersion: number;
  /** Root address already obtained by detection; when absent, computed from previewAPIRoot(input). */
  previewRoot?: string;
  /** Hint shown under the address (manual setup puts address hints under the key block and does not pass this). */
  error?: string;
}) {
  const t = useTranslations('pages.relaySetup');
  const endpointInputRef = useRef<HTMLInputElement>(null);
  const { endpointNormalizationVersion } = props;
  useEffect(() => {
    if (endpointNormalizationVersion <= 0) return;
    endpointInputRef.current?.focus();
    endpointInputRef.current?.select();
  }, [endpointNormalizationVersion]);
  // Preview value = detected root address ?? previewAPIRoot(input); null shows nothing.
  const root = props.previewRoot ?? previewAPIRoot(props.endpoint, RELAY_SECURITY_MODE);
  return (
    <div className={styles.field}>
      <label htmlFor="relay-request-url"><Link size={16} aria-hidden="true" />{t('requestURLLabel')}</label>
      <div className={styles.inputShell}>
        <span className={styles.schemeChip} data-testid="relay-endpoint-scheme" aria-hidden="true">
          {endpointSchemeChip(props.endpoint)}
        </span>
        <input
          ref={endpointInputRef}
          id="relay-request-url"
          className={styles.shellInput}
          type="url"
          value={endpointSlotText(props.endpoint)}
          placeholder={ENDPOINT_SLOT_PLACEHOLDER}
          onChange={(event) => props.onEndpointChange(endpointFromSlotInput(props.endpoint, event.target.value))}
          autoComplete="url"
          spellCheck={false}
          autoFocus
        />
      </div>
      {root ? (
        <small className={styles.previewLine} data-testid="relay-setup-will-request">
          <ArrowElbowDownRight size={13} className={styles.previewArrow} aria-hidden="true" />
          <span className={styles.previewText}>{t('twoStep.willRequest', { url: `${root}/…` })}</span>
        </small>
      ) : null}
      {props.error ? <span className={styles.fieldError}>{props.error}</span> : null}
    </div>
  );
}

/** API key block (shared slots for step 1 and manual setup): a single key has no name slot; with 2 or more keys each has an optional "Name"; plus add another key. */
export function RelaySetupKeySlots(props: {
  keys: RelayKeyDraft[];
  onKeyChange: (index: number, patch: Partial<Pick<RelayKeyDraft, 'apiKey' | 'name'>>) => void;
  onAddKey: () => void;
  onRemoveKey: (index: number) => void;
  showKey: boolean;
  onToggleKey: () => void;
  /** Hint shown under the key block (already localized). */
  issues: string[];
}) {
  const t = useTranslations('pages.relaySetup');
  const td = useTranslations('pages.providerDetail');
  const showsNames = relayShowsKeyNames(props.keys);
  return (
    <div className={styles.field}>
      {props.keys.map((key, index) => {
        const inputID = index === 0 ? 'relay-api-key' : `relay-api-key-${index}`;
        return (
          <div key={key.id} className={styles.keyEntry}>
            {/* Every key has a title row; the extra keys get a trailing "Remove". */}
            <div className={styles.keyHeader}>
              <label htmlFor={inputID}><Key size={16} aria-hidden="true" />{t('apiKeyLabel')}</label>
              {index > 0 ? (
                <button
                  type="button"
                  className={styles.keyRemove}
                  onClick={() => props.onRemoveKey(index)}
                  data-testid="relay_setup_remove_key_button"
                >
                  <Trash size={14} aria-hidden="true" />
                  <span>{t('twoStep.removeKey')}</span>
                </button>
              ) : null}
            </div>
            <div className={styles.keyShell}>
              <input
                id={inputID}
                className={styles.keyInput}
                value={key.apiKey /* key-choke: not-provider */}
                placeholder={API_KEY_PLACEHOLDER}
                onChange={(event) => props.onKeyChange(index, { apiKey: event.target.value })}
                {...getApiKeyInputProps(inputID, props.showKey ? 'visible' : 'masked')}
              />
              <button
                type="button"
                className={styles.iconButton}
                onClick={props.onToggleKey}
                aria-label={props.showKey ? td('hideKey') : td('showKey')}
              >
                <Eye size={18} weight={props.showKey ? 'duotone' : 'regular'} />
              </button>
            </div>
            {showsNames ? (
              // Name slot: label on the left inside the slot, input right-aligned.
              <div className={styles.inputShell}>
                <span className={styles.slotTag} aria-hidden="true">{t('twoStep.keyName')}</span>
                <input
                  className={`${styles.shellInput} ${styles.slotInputEnd}`}
                  aria-label={t('twoStep.keyName')}
                  value={key.name}
                  onChange={(event) => props.onKeyChange(index, { name: event.target.value })}
                  autoComplete="off"
                />
              </div>
            ) : null}
          </div>
        );
      })}
      <div className={styles.keyFooter}>
        <small>{t('apiKeyStaysOnDevice')}</small>
        <button type="button" className={styles.linkButton} onClick={props.onAddKey} data-testid="relay_setup_add_key_button">
          <Plus size={14} weight="bold" aria-hidden="true" />
          <span>{t('twoStep.addKey')}</span>
        </button>
      </div>
      {props.issues.map((issue) => <span key={issue} className={styles.fieldError}>{issue}</span>)}
    </div>
  );
}
