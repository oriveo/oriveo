'use client';

import { useEffect, useId, useRef, useState, type FormEvent } from 'react';
import { useTranslations } from 'next-intl';
import { Button, EyeIcon, EyeOffIcon } from '@oriveo/ui';
import { getApiKeyInputProps } from '../../../../lib/forms/api-key-input-props';
import { isPrintableAsciiKey } from '../../../../lib/utils/api-key-validation';
import { useFocusTrap } from '../../../../lib/hooks/useFocusTrap';
import styles from '../ProviderDetail.module.css';
import setupStyles from '../../new/ProviderSetup.module.css';

interface EditApiKeyDialogProps {
  /** Preview of the current key, shown in the subtitle so the user can tell which key is stored. */
  currentKeyPreview: string;
  onSave: (newKey: string) => void | Promise<void>;
  onCancel: () => void;
}

export function EditApiKeyDialog({ currentKeyPreview, onSave, onCancel }: EditApiKeyDialogProps) {
  const tSettings = useTranslations('pages.providerDetail.settings');
  const tc = useTranslations('common');
  const td = useTranslations('pages.providerDetail');

  const [value, setValue] = useState('');
  const [showKey, setShowKey] = useState(false);
  const [charsError, setCharsError] = useState<string | null>(null);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [isSaving, setIsSaving] = useState(false);
  const trimmed = value.trim();
  const canSave = trimmed.length > 0 && !isSaving;

  const dialogRef = useRef<HTMLDivElement>(null);
  const titleId = useId();
  useFocusTrap(dialogRef, true);

  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        onCancel();
      }
    };
    document.addEventListener('keydown', handler);
    return () => document.removeEventListener('keydown', handler);
  }, [onCancel]);

  const submit = async () => {
    if (!canSave) return;
    if (!isPrintableAsciiKey(trimmed)) {
      setCharsError(tc('apiKeyInvalidChars'));
      return;
    }
    setCharsError(null);
    setSaveError(null);
    setIsSaving(true);
    try {
      await onSave(trimmed);
    } catch (err) {
      setSaveError(err instanceof Error ? err.message : tc('error'));
    } finally {
      setIsSaving(false);
    }
  };

  const handleSubmit = (e: FormEvent) => {
    e.preventDefault();
    submit();
  };

  return (
    <div className={styles.confirmOverlay} onClick={onCancel}>
      <div
        ref={dialogRef}
        className={styles.confirmDialog}
        onClick={(e) => e.stopPropagation()}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
      >
        <div id={titleId} className={styles.confirmTitle}>{tSettings('editApiKey')}</div>
        <form onSubmit={handleSubmit}>
          <div className={setupStyles.keyInputWrap}>
          <input
            className={styles.providerNameInput}
            value={value}
            placeholder={currentKeyPreview ? `••••••••••• ${currentKeyPreview}` : 'sk-...'}
            onChange={(e) => {
              setValue(e.target.value);
              if (charsError) setCharsError(null);
              if (saveError) setSaveError(null);
            }}
            autoFocus
            {...getApiKeyInputProps('edit-api-key', showKey ? 'visible' : 'masked')}
            aria-label={tSettings('editApiKey')}
            style={{ width: '100%', paddingRight: 40 }}
          />
          <button
            type="button"
            className={setupStyles.toggleVis}
            onClick={() => setShowKey((v) => !v)}
            aria-label={showKey ? td('hideKey') : td('showKey')}
          >
            {showKey ? <EyeOffIcon /> : <EyeIcon />}
          </button>
          </div>
          {charsError && (
            <div className={styles.editFieldError} role="alert" style={{ marginTop: 8 }}>
              {charsError}
            </div>
          )}
          {saveError && (
            <div className={styles.editFieldError} role="alert" style={{ marginTop: 8 }}>
              {saveError}
            </div>
          )}
        </form>
        <div className={styles.confirmActions}>
          <Button tone="secondary" size="sm" onClick={onCancel}>
            {tc('cancel')}
          </Button>
          <Button tone="primary" size="sm" onClick={submit} disabled={!canSave}>
            {tc('save')}
          </Button>
        </div>
      </div>
    </div>
  );
}
