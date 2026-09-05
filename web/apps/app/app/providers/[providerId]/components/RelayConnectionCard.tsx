'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import type { ReactNode } from 'react';
import { useTranslations } from 'next-intl';
import {
  ChevronRight,
  CircleCheck,
  Globe,
  KeyRound,
  Loader2,
  Pencil,
  TriangleAlert,
  X,
  Zap,
} from 'lucide-react';
import { Button } from '@oriveo/ui';
import type { RelayCredentialState } from '../../../../lib/core/providers/relay-runtime-support';
import styles from './RelayConnectionCard.module.css';

/** The verdict comes from the shared relay form validation helpers in the layer above; this component never judges an address or key itself. */
type RelayFieldCheck<Extra = unknown> =
  | ({ ok: true } & Extra)
  | { ok: false; message: string };

interface RelayConnectionCardProps {
  /** Current endpoint text, already read from the Provider */
  endpoint: string;
  /** Placeholder for editing the endpoint */
  endpointPlaceholder?: string;
  /** Placeholder for the API key input */
  apiKeyPlaceholder?: string;
  /** Incremented when the layer above adds a scheme before sending and writes it back; the component must enter edit mode and select the real normalized address. */
  endpointNormalizationVersion?: number;
  normalizedEndpointToReveal?: string;
  /** Always-visible read-only connection type summary plus the explicit change confirmation panel. */
  connectionTypeSlot: ReactNode;
  /** Save the endpoint; the value received is already normalized */
  onSaveEndpoint: (next: string) => Promise<boolean> | boolean;
  /**
   * Address validation. Uses the shared form validation in edit mode, measuring the address
   * against this connection's own `securityMode` through the same entry function the save path
   * uses, so form validation and saving can never disagree.
   */
  onValidateEndpoint: (raw: string) => RelayFieldCheck<{ normalized: string }>;
  /** Key validation (cleartext interlock plus character set). Also from the shared helpers; this component copies no rule of its own. */
  onValidateApiKey: (raw: string) => RelayFieldCheck;

  /**
   * Credential state S0 to S3, derived by `relayProviderCredentialState`.
   * The component never receives the real key (the edit flow does not prefill plaintext), only
   * the state plus a masked string.
   */
  credentialState: RelayCredentialState;
  /** The connection uses a cleartext channel (local_http / private_vpn), which adds a "no credentials will be sent" line in S0 */
  isCleartext?: boolean;
  /** Display only: API key preview, first four characters, mask, last four; empty string when there is no key */
  apiKeyPreview: string;
  /** After saving a new key, wait for real generation verification to finish rather than collapsing early while still in the old Connected state. */
  onSaveApiKey: (next: string) => Promise<void> | void;
  /** Remove the key: falls back to S1 without changing authMode */
  onRemoveApiKey?: () => void;
  /** Way out of S3: clear all credential material and stay on a cleartext connection (authMode goes to none and the key is deleted) */
  onClearCredentials?: () => void;
  /** Second way out of S3: explicitly upgrade to HTTPS, reusing the mode-switch reconnect transaction above. */
  onSwitchToHttps?: () => void;

  /** Invoked by the Test connection button */
  onTestConnection: () => void;
  isTestingConnection: boolean;
  /** null means no result; an object describes the outcome of this test */
  testResult: { ok: boolean; message: string } | null;

  /** Disable the whole card, for example while saving */
  isSubmitting?: boolean;
}

export function RelayConnectionCard({
  endpoint,
  endpointPlaceholder = 'https://api.example.com/v1',
  apiKeyPlaceholder = 'sk-...',
  endpointNormalizationVersion = 0,
  normalizedEndpointToReveal,
  connectionTypeSlot,
  onSaveEndpoint,
  onValidateEndpoint,
  onValidateApiKey,
  credentialState,
  isCleartext,
  apiKeyPreview,
  onSaveApiKey,
  onRemoveApiKey,
  onClearCredentials,
  onSwitchToHttps,
  onTestConnection,
  isTestingConnection,
  testResult,
  isSubmitting,
}: RelayConnectionCardProps) {
  const tr = useTranslations('pages.relayDetail');
  const t = useTranslations('pages.providerDetail');
  const tc = useTranslations('common');

  const [endpointEditing, setEndpointEditing] = useState(false);
  const [endpointDraft, setEndpointDraft] = useState(endpoint);
  const [endpointError, setEndpointError] = useState<string | null>(null);
  const [isSavingEndpoint, setIsSavingEndpoint] = useState(false);
  const endpointInputRef = useRef<HTMLInputElement>(null);
  useEffect(() => {
    if (!endpointEditing) setEndpointDraft(endpoint);
  }, [endpoint, endpointEditing]);
  useEffect(() => {
    if (endpointNormalizationVersion <= 0) return;
    setEndpointDraft(normalizedEndpointToReveal ?? endpoint);
    setEndpointError(null);
    setEndpointEditing(true);
    requestAnimationFrame(() => {
      endpointInputRef.current?.focus();
      endpointInputRef.current?.select();
    });
  }, [endpoint, endpointNormalizationVersion, normalizedEndpointToReveal]);

  const handleSaveEndpoint = useCallback(async () => {
    const check = onValidateEndpoint(endpointDraft);
    if (!check.ok) {
      setEndpointError(check.message);
      return;
    }
    setIsSavingEndpoint(true);
    try {
      const saved = await onSaveEndpoint(check.normalized);
      if (!saved) return;
      setEndpointError(null);
      if (check.normalized !== endpointDraft.trim()) {
        setEndpointDraft(check.normalized);
        setEndpointEditing(true);
        requestAnimationFrame(() => {
          endpointInputRef.current?.focus();
          endpointInputRef.current?.select();
        });
      } else {
        setEndpointEditing(false);
      }
    } finally {
      setIsSavingEndpoint(false);
    }
  }, [endpointDraft, onSaveEndpoint, onValidateEndpoint]);

  const [keyEditing, setKeyEditing] = useState(false);
  const [keyDraft, setKeyDraft] = useState('');
  const [keyError, setKeyError] = useState<string | null>(null);
  const [isSavingKey, setIsSavingKey] = useState(false);
  const keyInputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (keyEditing) {
      // The edit field always starts empty: the component never receives the real key and never puts a stored key back on screen
      setKeyDraft('');
      setKeyError(null);
      // autoFocus is applied after the first frame
      requestAnimationFrame(() => keyInputRef.current?.focus());
    }
  }, [keyEditing]);

  const handleSaveKey = useCallback(async () => {
    const trimmed = keyDraft.trim();
    if (!trimmed) {
      // This is a precondition of the key sub-editor itself (it is opened precisely to set a key),
      // not a form-level required field: whole-form validation in edit mode never treats the key as
      // required. A rejected save must always show a visible reason.
      setKeyError(tr('apiKeyRequired'));
      return;
    }
    // The cleartext interlock, whose reason points at the connection type rather than at an invalid key, and the character set both come from the shared helpers
    const check = onValidateApiKey(keyDraft);
    if (!check.ok) {
      setKeyError(check.message);
      return;
    }
    setIsSavingKey(true);
    try {
      await onSaveApiKey(keyDraft);
      setKeyEditing(false);
    } catch {
      // The state machine has already written the new key and a stable issue status back to the store; the editor keeps the input so the user can correct it and retry.
      setKeyError(tr('testRelayFailed'));
    } finally {
      setIsSavingKey(false);
    }
  }, [keyDraft, onSaveApiKey, onValidateApiKey, tr]);

  const trimmedEndpoint = endpoint.trim();
  const hasEndpoint = trimmedEndpoint.length > 0;

  return (
    <section className={styles.section}>
      <div className={styles.groupHeader}>
        <span className={styles.groupIcon} aria-hidden="true">
          <Globe size={11} strokeWidth={2.6} />
        </span>
        <span className={styles.groupTitle}>{tr('connectionTitle')}</span>
      </div>

      <div className={styles.stack}>
        {/* ── Endpoint block ── */}
        <div className={styles.endpointBlock}>
          <span className={styles.endpointLabel}>{tr('endpoint')}</span>
          {endpointEditing ? (
            <div className={styles.endpointInputWrap}>
              <Globe size={13} strokeWidth={2.4} className={styles.endpointGlobe} aria-hidden="true" />
              <input
                ref={endpointInputRef}
                type="url"
                className={styles.endpointInput}
                value={endpointDraft}
                placeholder={endpointPlaceholder}
                onChange={(e) => {
                  setEndpointDraft(e.target.value);
                  if (endpointError) setEndpointError(null);
                }}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') void handleSaveEndpoint();
                  if (e.key === 'Escape') {
                    setEndpointDraft(endpoint);
                    setEndpointError(null);
                    setEndpointEditing(false);
                  }
                }}
                autoCapitalize="off"
                autoCorrect="off"
                autoComplete="off"
                spellCheck={false}
                inputMode="url"
                disabled={isSubmitting || isSavingEndpoint || isSavingKey}
                autoFocus
              />
              <div className={styles.endpointActions}>
                <Button
                  tone="primary"
                  size="sm"
                  onClick={() => { void handleSaveEndpoint(); }}
                  disabled={isSubmitting || isSavingEndpoint}
                >
                  {tr('verifyAndSave')}
                </Button>
                <button
                  type="button"
                  className={styles.endpointEditBtn}
                  onClick={() => {
                    setEndpointDraft(endpoint);
                    setEndpointError(null);
                    setEndpointEditing(false);
                  }}
                  aria-label={tc('cancel')}
                >
                  <X size={14} strokeWidth={2.4} aria-hidden="true" />
                </button>
              </div>
            </div>
          ) : (
            <div className={styles.endpointDisplay}>
              <Globe size={13} strokeWidth={2.4} className={styles.endpointGlobe} aria-hidden="true" />
              {hasEndpoint ? (
                <span className={styles.endpointValue} title={trimmedEndpoint}>
                  {trimmedEndpoint}
                </span>
              ) : (
                <span className={styles.endpointPlaceholderText}>{endpointPlaceholder}</span>
              )}
              <button
                type="button"
                className={styles.endpointEditBtn}
                onClick={() => setEndpointEditing(true)}
                aria-label={t('editBaseURL')}
                disabled={isSubmitting}
              >
                <Pencil size={13} strokeWidth={2.4} aria-hidden="true" />
              </button>
            </div>
          )}
          {endpointError && (
            <div className={styles.endpointError} role="alert">
              {endpointError}
            </div>
          )}
        </div>

        <div className={styles.divider} aria-hidden="true" />

        {connectionTypeSlot}

        <div className={styles.divider} aria-hidden="true" />

        {/* -- API Key block: five credential states (S0 neutral, S1 warning, S2 masked, S3 blocking; S4 is carried by provider.status) -- */}
        {keyEditing ? (
          <div className={styles.apiKeyEdit}>
            <span className={styles.iconBox} data-tone="warning" aria-hidden="true">
              <KeyRound size={14} strokeWidth={2.4} />
            </span>
            <div className={styles.apiKeyEditStack}>
              <input
                ref={keyInputRef}
                type="password"
                className={styles.apiKeyEditInput}
                value={keyDraft}
                onChange={(e) => {
                  setKeyDraft(e.target.value);
                  if (keyError) setKeyError(null);
                }}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') handleSaveKey();
                  if (e.key === 'Escape') {
                    setKeyEditing(false);
                    setKeyError(null);
                  }
                }}
                placeholder={credentialState === 'present' ? tr('savedPlaceholder') : apiKeyPlaceholder}
                autoCapitalize="off"
                autoCorrect="off"
                autoComplete="off"
                spellCheck={false}
                aria-label={t('apiKey')}
                disabled={isSubmitting || isSavingKey}
              />
              <span className={styles.rowSubtitle}>{tr('rotateKeyNote')}</span>
              {keyError && (
                <div className={styles.apiKeyEditError} role="alert">
                  {keyError}
                </div>
              )}
            </div>
            <div className={styles.apiKeyEditActions}>
              <Button
                tone="primary"
                size="sm"
                onClick={handleSaveKey}
                disabled={isSubmitting || isSavingKey || keyDraft.trim().length === 0}
              >
                {isSavingKey ? tr('rotatingKey') : t('saveKey')}
              </Button>
              {credentialState === 'present' && onRemoveApiKey && (
                <Button
                  tone="secondary"
                  size="sm"
                  onClick={() => {
                    setKeyEditing(false);
                    setKeyError(null);
                    onRemoveApiKey();
                  }}
                  disabled={isSubmitting || isSavingKey}
                >
                  {tr('removeKey')}
                </Button>
              )}
              <button
                type="button"
                className={styles.endpointEditBtn}
                onClick={() => {
                  setKeyEditing(false);
                  setKeyError(null);
                }}
                aria-label={tc('cancel')}
                disabled={isSavingKey}
              >
                <X size={14} strokeWidth={2.4} aria-hidden="true" />
              </button>
            </div>
          </div>
        ) : credentialState === 'not_required' ? (
          // S0: this connection needs no key at all. Neutral wording, no warning colour and no call to action, since it is the normal state for a local engine
          <div className={styles.apiKeyStaticRow}>
            <span className={styles.iconBox} data-tone="neutral" aria-hidden="true">
              <KeyRound size={14} strokeWidth={2.4} />
            </span>
            <div className={styles.rowStack}>
              <span className={styles.rowTitle}>{t('apiKey')}</span>
              <span className={styles.rowSubtitle}>{tr('credentialNotRequired')}</span>
              {isCleartext && (
                <span className={styles.rowSubtitle}>{tr('credentialNotSentNote')}</span>
              )}
            </div>
            {(apiKeyPreview || '').trim().length > 0 && onRemoveApiKey && (
              <Button tone="secondary" size="sm" onClick={onRemoveApiKey} disabled={isSubmitting}>
                {tr('removeKey')}
              </Button>
            )}
          </div>
        ) : credentialState === 'conflict' ? (
          // S3: a cleartext connection still carrying credential material. A blocking state that offers only ways out and no "save anyway"
          <div className={styles.apiKeyStaticRow} role="alert">
            <span className={styles.iconBox} data-tone="error" aria-hidden="true">
              <TriangleAlert size={14} strokeWidth={2.4} />
            </span>
            <div className={styles.rowStack}>
              <span className={styles.rowTitle}>{t('apiKey')}</span>
              <span className={styles.rowSubtitle} data-tone="error">
                {tr('cleartextCredentialsBlocked')}
              </span>
            </div>
            {onClearCredentials && (
              <Button tone="primary" size="sm" onClick={onClearCredentials} disabled={isSubmitting}>
                {tr('clearAndStay')}
              </Button>
            )}
            {onSwitchToHttps && (
              <Button tone="secondary" size="sm" onClick={onSwitchToHttps} disabled={isSubmitting}>
                {tr('switchToHttpsConnection')}
              </Button>
            )}
          </div>
        ) : (
          <button
            type="button"
            className={styles.apiKeyRow}
            onClick={() => setKeyEditing(true)}
            disabled={isSubmitting}
            aria-label={credentialState === 'present' ? t('editKey') : t('apiKey')}
          >
            <span
              className={styles.iconBox}
              data-tone={credentialState === 'present' ? 'neutral' : 'warning'}
              aria-hidden="true"
            >
              <KeyRound size={14} strokeWidth={2.4} />
            </span>
            <div className={styles.rowStack}>
              <span className={styles.rowTitle}>{t('apiKey')}</span>
              {credentialState === 'present' ? (
                <span className={styles.rowSubtitle} data-mono="true" title={apiKeyPreview}>
                  {apiKeyPreview}
                </span>
              ) : (
                <span className={styles.rowSubtitle} data-tone="warning">
                  {tr('apiKeyRequired')}
                </span>
              )}
            </div>
            <span className={styles.changeCapsule}>
              {credentialState === 'present' ? tr('changeKey') : tr('addKey')}
            </span>
          </button>
        )}

        <div className={styles.divider} aria-hidden="true" />

        {/* -- Test connection block: clicking is allowed even with an empty endpoint, and onTestConnection guards it with an "endpoint is empty" notice -- */}
        <button
          type="button"
          className={styles.testRow}
          onClick={onTestConnection}
          disabled={isTestingConnection || isSubmitting}
          aria-label={isTestingConnection ? tr('testingRelay') : tr('testRelay')}
        >
          <span className={styles.iconBox} data-tone="connection" aria-hidden="true">
            {isTestingConnection ? (
              <Loader2 size={14} strokeWidth={2.6} className={styles.spin} />
            ) : (
              <Zap size={14} strokeWidth={2.6} />
            )}
          </span>
          <div className={styles.rowStack}>
            <span className={styles.rowTitle}>
              {isTestingConnection ? tr('testingRelay') : tr('testRelay')}
            </span>
            <span className={styles.rowSubtitle}>{tr('testRelayHint')}</span>
          </div>
          <ChevronRight size={14} strokeWidth={2.6} className={styles.rowChevron} aria-hidden="true" />
        </button>

        {testResult && (
          <div className={styles.testResult} data-tone={testResult.ok ? 'success' : 'error'} role="status">
            <span className={styles.testResultIcon} aria-hidden="true">
              {testResult.ok ? (
                <CircleCheck size={14} strokeWidth={2.4} />
              ) : (
                <TriangleAlert size={14} strokeWidth={2.4} />
              )}
            </span>
            <span className={styles.testResultText}>{testResult.message}</span>
          </div>
        )}
      </div>
    </section>
  );
}
