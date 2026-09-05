'use client';

import { useMemo, useState } from 'react';
import { useTranslations } from 'next-intl';
import { Check, ChevronRight, Globe2, LockKeyhole, Network, TriangleAlert, X } from 'lucide-react';
import { Button } from '@oriveo/ui';
import type { RelayConnectionSecurityMode } from '@oriveo/shared';
import {
  normalizeEndpointForSecurityMode,
  relaySecurityModeDecision,
  type RelaySelectableSecurityMode,
  type RelaySecurityModeUnavailableReason,
} from '@oriveo/core/providers/relay-security-mode';
import styles from './RelaySecurityModeControl.module.css';

export interface RelaySecurityModeControlProps {
  value: RelayConnectionSecurityMode;
  endpoint: string;
  hasCredentialMaterial: boolean;
  onChange: (input: {
    mode: RelaySelectableSecurityMode;
    normalizedEndpoint: string;
  }) => void | Promise<void>;
  busy?: boolean;
  error?: string;
}

export function RelaySecurityModeControl({
  value,
  endpoint,
  hasCredentialMaterial,
  onChange,
  busy = false,
  error,
}: RelaySecurityModeControlProps) {
  const t = useTranslations('pages.relayDetail');
  const tc = useTranslations('common');
  const [open, setOpen] = useState(false);
  const [pending, setPending] = useState<RelaySelectableSecurityMode | null>(null);
  const [applying, setApplying] = useState(false);
  const decision = useMemo(() => relaySecurityModeDecision(endpoint), [endpoint]);

  const apply = async (mode: RelaySelectableSecurityMode) => {
    const normalizedEndpoint = normalizeEndpointForSecurityMode(endpoint, mode);
    if (!normalizedEndpoint) return;
    setApplying(true);
    try {
      await onChange({ mode, normalizedEndpoint });
      setPending(null);
      setOpen(false);
    } finally {
      setApplying(false);
    }
  };

  const select = (mode: RelaySelectableSecurityMode) => {
    if (mode === value) {
      // An address with no scheme under the current mode still goes through the same apply
      // transaction: normalize and write it back first, then let the layer above send the
      // request. Only an already normalized address just closes the panel, avoiding a second probe.
      const normalizedEndpoint = normalizeEndpointForSecurityMode(endpoint, mode);
      if (normalizedEndpoint && normalizedEndpoint !== endpoint.trim()) {
        void apply(mode);
        return;
      }
      setOpen(false);
      return;
    }
    if (mode === 'local_http' || mode === 'private_vpn') {
      // The first tap only enters the confirmation state and never writes the mode; even with no credentials the plaintext risk must be confirmed explicitly.
      setPending(mode);
      return;
    }
    void apply(mode);
  };

  return (
    <div className={styles.root}>
      <button
        type="button"
        className={styles.summary}
        onClick={() => { setPending(null); setOpen(true); }}
        disabled={busy || applying}
        aria-label={t('changeConnectionType')}
      >
        <span className={styles.icon} aria-hidden="true">{modeIcon(value)}</span>
        <span className={styles.summaryText}>
          <span className={styles.label}>{t('connectionType')}</span>
          <span className={styles.value}>{t(modeLabelKey(value))}</span>
          {value === 'tofu_https' ? (
            <span className={styles.value}>{t(modeDescriptionKey(value))}</span>
          ) : null}
        </span>
        <span className={styles.change}>{t('changeConnectionTypeShort')}</span>
        <ChevronRight size={14} aria-hidden="true" />
      </button>
      {error ? <span className={styles.error} role="alert">{error}</span> : null}

      {open ? (
        <div className={styles.panel} role="dialog" aria-label={t('connectionType')}>
          <div className={styles.panelHeader}>
            <div>
              <strong>{t('connectionType')}</strong>
              <p>{t('connectionTypeHint')}</p>
            </div>
            <button type="button" className={styles.close} onClick={() => setOpen(false)} aria-label={tc('cancel')}>
              <X size={15} aria-hidden="true" />
            </button>
          </div>

          {decision.suggestion && decision.suggestion !== value ? (
            <div className={styles.suggestion} role="status">
              {t('connectionTypeSuggestion', { mode: t(modeLabelKey(decision.suggestion)) })}
            </div>
          ) : null}

          <div className={styles.options}>
            {decision.options.map((option) => {
              const selected = option.mode === value;
              return (
                <button
                  key={option.mode}
                  type="button"
                  className={styles.option}
                  data-selected={selected}
                  disabled={(!option.enabled && !selected) || busy || applying}
                  onClick={() => select(option.mode)}
                >
                  <span className={styles.optionIcon} aria-hidden="true">{modeIcon(option.mode)}</span>
                  <span className={styles.optionText}>
                    <strong>{t(modeLabelKey(option.mode))}</strong>
                    <small>{option.enabled || selected
                      ? t(modeDescriptionKey(option.mode))
                      : t(unavailableKey(option.unavailableReason))}</small>
                  </span>
                  {selected ? <Check size={16} aria-hidden="true" /> : null}
                </button>
              );
            })}
          </div>

          {pending ? (
            <div className={styles.confirm} role="alert">
              <TriangleAlert size={18} aria-hidden="true" />
              <div className={styles.confirmText}>
                <strong>{t('confirmPlainHttpTitle')}</strong>
                <p>{hasCredentialMaterial
                  ? t('securityModeClearCredentialsWarning')
                  : t('securityModePlainHttpWarning')}</p>
                <div className={styles.confirmActions}>
                  <Button tone="secondary" size="sm" onClick={() => setPending(null)} disabled={applying}>
                    {tc('cancel')}
                  </Button>
                  <Button tone="primary" size="sm" onClick={() => void apply(pending)} disabled={applying}>
                    {hasCredentialMaterial ? t('clearCredentialsAndSwitch') : t('confirmPlainHttp')}
                  </Button>
                </div>
              </div>
            </div>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

function modeIcon(mode: RelayConnectionSecurityMode) {
  if (mode === 'local_http') return <Network size={16} />;
  if (mode === 'private_vpn') return <Globe2 size={16} />;
  return <LockKeyhole size={16} />;
}

function modeLabelKey(mode: RelayConnectionSecurityMode) {
  if (mode === 'local_http') return 'connectionTypeLocalHttp';
  if (mode === 'private_vpn') return 'connectionTypePrivateVpn';
  if (mode === 'tofu_https') return 'connectionTypePairedHttps';
  return 'connectionTypeRemoteHttps';
}

function modeDescriptionKey(mode: RelayConnectionSecurityMode) {
  if (mode === 'local_http') return 'connectionTypeLocalHttpDesc';
  if (mode === 'private_vpn') return 'connectionTypePrivateVpnDesc';
  if (mode === 'tofu_https') return 'connectionTypePairedHttpsDesc';
  return 'connectionTypeRemoteHttpsDesc';
}

function unavailableKey(reason: RelaySecurityModeUnavailableReason | undefined) {
  switch (reason) {
    case 'endpoint_required': return 'endpointEmpty';
    case 'https_scheme_required':
    case 'plain_http_scheme_required': return 'securityModeSchemeMismatch';
    case 'public_address': return 'connectionTypePublicDisabled';
    case 'mixed_resolution':
    case 'unknown_address':
    case 'invalid_address':
    default: return 'connectionTypeInvalidAddress';
  }
}
