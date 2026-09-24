'use client';

import { useState, type InputHTMLAttributes } from 'react';
import { useTranslations } from 'next-intl';
import { EyeIcon, EyeOffIcon, Input } from '@oriveo/ui';
import styles from './BackupPage.module.css';

type BackupPasswordInputProps = Omit<InputHTMLAttributes<HTMLInputElement>, 'type'>;

/**
 * Backup encryption / decryption password field with the same reveal button as the API key field, so the
 * input can be checked. The screen reader labels match the iOS / Android password fields
 * (Show characters / Hide characters) and do not say "key".
 */
export function BackupPasswordInput(props: BackupPasswordInputProps) {
  const tc = useTranslations('common');
  const [revealed, setRevealed] = useState(false);

  return (
    <div className={styles.passwordField}>
      <Input {...props} type={revealed ? 'text' : 'password'} />
      <button
        type="button"
        className={styles.passwordToggle}
        onClick={() => setRevealed((value) => !value)}
        aria-label={revealed ? tc('hideCharacters') : tc('showCharacters')}
      >
        {revealed ? <EyeOffIcon /> : <EyeIcon />}
      </button>
    </div>
  );
}
