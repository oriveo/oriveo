'use client';

import { useCallback, useId, useRef, useState, type ReactNode } from 'react';
import { useTranslations } from 'next-intl';
import { EyeIcon, XIcon } from '@phosphor-icons/react';
import { Button } from '@oriveo/ui';
import { useFocusTrap } from '../../../../lib/hooks/useFocusTrap';
import { getApiKeyInputProps } from '../../../../lib/forms/api-key-input-props';
import styles from '../ProviderDetail.module.css';
import boardStyles from './RelayDetailBoard.module.css';

type RelayKeyCheck = { ok: true } | { ok: false; message: string };

/**
 * Shell for the add / replace key / rename input surface: keeps the Dialog container; close × at top left + centered title,
 * a single full-width Save at the bottom, no Cancel.
 */
export function RelayKeyInputShell({
  title,
  onClose,
  onSave,
  saveDisabled,
  saveLabel,
  busy = false,
  children,
}: {
  title: string;
  onClose: () => void;
  onSave: () => void;
  saveDisabled: boolean;
  /** Defaults to common.save. */
  saveLabel?: string;
  /** While saving: clicking the backdrop / × / Esc does not close it. */
  busy?: boolean;
  children: ReactNode;
}) {
  const tRoot = useTranslations();
  const dialogRef = useRef<HTMLDivElement>(null);
  const titleId = useId();
  useFocusTrap(dialogRef, true);
  const close = () => {
    if (!busy) onClose();
  };
  return (
    <div className={styles.confirmOverlay} onClick={close}>
      <div
        ref={dialogRef}
        className={styles.confirmDialog}
        onClick={(event) => event.stopPropagation()}
        onKeyDown={(event) => {
          if (event.key === 'Escape') close();
        }}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
      >
        <div className={boardStyles.keyInputHeader} data-key-input-header>
          <button
            type="button"
            className={boardStyles.keyInputClose}
            onClick={close}
            disabled={busy}
            aria-label={tRoot('common.close')}
            title={tRoot('common.close')}
          >
            <XIcon size={14} weight="bold" aria-hidden="true" />
          </button>
          <div id={titleId} className={boardStyles.keyInputTitle} data-key-input-title>{title}</div>
          <span aria-hidden="true" />
        </div>
        {children}
        <Button
          tone="primary"
          className={boardStyles.keyInputSave}
          data-key-input-save
          onClick={onSave}
          disabled={saveDisabled}
        >
          {saveLabel ?? tRoot('common.save')}
        </Button>
      </div>
    </div>
  );
}

/** Input with a visible title on the input surface (same style as the settings-page key slot); with `secret` it shows a show / hide eye. */
export function RelayKeyTextField({
  label,
  value,
  onChange,
  onEnter,
  placeholder,
  secret = false,
  autoFocus = false,
  disabled = false,
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  onEnter: () => void;
  placeholder?: string;
  secret?: boolean;
  autoFocus?: boolean;
  disabled?: boolean;
}) {
  const tRoot = useTranslations();
  const inputId = useId();
  const [visible, setVisible] = useState(false);
  const inputProps = secret
    ? { ...getApiKeyInputProps(inputId, visible ? 'visible' : 'masked'), 'data-key-input-secret': true }
    : { autoComplete: 'off', spellCheck: false };
  return (
    <div className={boardStyles.keyInputField}>
      <label className={boardStyles.keyInputLabel} htmlFor={inputId}>{label}</label>
      <div className={boardStyles.keyInputSlot}>
        <input
          id={inputId}
          className={[
            boardStyles.keyInputBox,
            secret ? boardStyles.keyInputSecret : '',
          ].filter(Boolean).join(' ')}
          value={value}
          onChange={(event) => onChange(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'Enter') onEnter();
          }}
          placeholder={placeholder}
          autoFocus={autoFocus}
          disabled={disabled}
          {...inputProps}
        />
        {secret && (
          <button
            type="button"
            className={boardStyles.keyInputReveal}
            onClick={() => setVisible((current) => !current)}
            aria-label={tRoot(visible ? 'pages.providerDetail.hideKey' : 'pages.providerDetail.showKey')}
          >
            <EyeIcon size={18} weight={visible ? 'duotone' : 'regular'} aria-hidden="true" />
          </button>
        )}
      </div>
    </div>
  );
}

interface RelayApiKeyDialogProps {
  /** When a key is already stored, offer "Remove key"; the input placeholder hints "Saved". */
  hasSavedKey: boolean;
  placeholder: string;
  /** Plaintext interlock and charset both use the shared form validation; this component does not duplicate the criteria. */
  onValidate: (raw: string) => RelayKeyCheck;
  /** After saving a new key, close only once real generation verification finishes. */
  onSave: (next: string) => Promise<void> | void;
  /** Remove key: only goes back to the no-key state, does not change authMode. */
  onRemove?: () => void;
  onClose: () => void;
  disabled?: boolean;
  /** Used by the keys page "Replace key": title / field name / description; when omitted, the detail page's single-key dialog wording is used. */
  title?: string;
  fieldLabel?: string;
  description?: string;
}

/**
 * Replace-key input surface (shared by the detail page's single key and the keys page "Replace key"): initial value always empty, masked by default, never echoes the stored key.
 */
export function RelayApiKeyDialog({
  hasSavedKey,
  placeholder,
  onValidate,
  onSave,
  onRemove,
  onClose,
  disabled,
  title,
  fieldLabel,
  description,
}: RelayApiKeyDialogProps) {
  const tr = useTranslations('pages.relayDetail');
  const t = useTranslations('pages.providerDetail');
  const [draft, setDraft] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [isSaving, setIsSaving] = useState(false);

  const save = useCallback(async () => {
    if (!draft.trim()) {
      // This is opened precisely to set a key: saving an empty value must have a visible reason, not a form-level required.
      setError(tr('apiKeyRequired'));
      return;
    }
    const check = onValidate(draft);
    if (!check.ok) {
      setError(check.message);
      return;
    }
    setIsSaving(true);
    try {
      await onSave(draft);
      onClose();
    } catch {
      // The state machine has already written the new key and a stable issue back to the store; keep the input so the user can fix it and retry.
      setError(tr('testRelayFailed'));
    } finally {
      setIsSaving(false);
    }
  }, [draft, onClose, onSave, onValidate, tr]);

  return (
    <RelayKeyInputShell
      title={title ?? t('apiKey')}
      onClose={onClose}
      onSave={() => { void save(); }}
      saveDisabled={Boolean(disabled) || isSaving || draft.trim().length === 0}
      saveLabel={isSaving ? tr('rotatingKey') : undefined}
      busy={isSaving}
    >
      <RelayKeyTextField
        label={fieldLabel ?? t('apiKey')}
        value={draft}
        onChange={(value) => {
          setDraft(value);
          if (error) setError(null);
        }}
        onEnter={() => { void save(); }}
        placeholder={hasSavedKey ? tr('savedPlaceholder') : placeholder}
        secret
        autoFocus
        disabled={disabled || isSaving}
      />
      <div className={styles.confirmDesc}>{description ?? tr('rotateKeyNote')}</div>
      {error && (
        <div className={styles.editFieldError} role="alert">
          {error}
        </div>
      )}
      {hasSavedKey && onRemove && (
        <button
          type="button"
          className={boardStyles.keyInputRemove}
          onClick={() => {
            onClose();
            onRemove();
          }}
          disabled={disabled || isSaving}
        >
          {tr('removeKey')}
        </button>
      )}
    </RelayKeyInputShell>
  );
}
