'use client';

import { useState } from 'react';
import { useTranslations } from 'next-intl';
import { Button, Dialog, Input } from '@oriveo/ui';
import { exportBackup, saveBackupFile } from '../../../lib/backup';
import { useAppStore } from '../../../providers/StoreProvider';
import styles from './BackupPage.module.css';

export function ExportSection() {
  const t = useTranslations('pages.backup');
  const tc = useTranslations('common');

  const conversations = useAppStore((s) => s.conversations);
  const providers = useAppStore((s) => s.providers);
  const conversationCount = conversations.length;
  const providerCount = providers.length;
  const totalMessages = conversations.reduce((sum, c) => sum + c.messages.length, 0);

  const [exportPassword, setExportPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [includeKeys, setIncludeKeys] = useState(false);
  const [exporting, setExporting] = useState(false);
  const [exportError, setExportError] = useState('');
  const [exportSuccess, setExportSuccess] = useState(false);

  async function handleExport() {
    if (includeKeys && exportPassword !== confirmPassword) {
      setExportError(t('passwordMismatch'));
      return;
    }
    if (includeKeys && exportPassword.length < 8) {
      setExportError(t('passwordTooShort'));
      return;
    }

    setExporting(true);
    setExportError('');
    setExportSuccess(false);

    try {
      const blob = await exportBackup({
        includeApiKeys: includeKeys,
        password: includeKeys ? exportPassword : undefined,
      });
      const filename = `Oriveo-Backup-${new Date().toISOString().slice(0, 10)}.oriveo`;
      await saveBackupFile(blob, filename);
      setExportSuccess(true);
    } catch (err: any) {
      if (err?.name === 'AbortError') {
        // The user dismissed the file picker.
      } else {
        setExportError(t('exportFailed'));
      }
    } finally {
      setExporting(false);
    }
  }

  return (
    <>
      <div className={styles.section}>
        <h2 className={styles.sectionTitle}>{t('exportSection')}</h2>
        <p className={styles.sectionHint}>{t('exportDescription')}</p>
        <p className={styles.sectionHint}>{t('exportPrivateCatalogNotice')}</p>
        <div className={styles.form}>
          <label className={styles.checkboxRow}>
            <input
              type="checkbox"
              checked={includeKeys}
              onChange={(e) => setIncludeKeys(e.target.checked)}
            />
            {t('includeApiKeys')}
          </label>
          {includeKeys && (
            <>
              <div className={styles.fieldGroup}>
                <label className={styles.fieldLabel}>{t('encryptionPassword')}</label>
                <Input
                  type="password"
                  placeholder={t('passwordPlaceholder')}
                  value={exportPassword}
                  onChange={(e) => setExportPassword(e.target.value)}
                />
              </div>
              <div className={styles.fieldGroup}>
                <label className={styles.fieldLabel}>{t('confirmPassword')}</label>
                <Input
                  type="password"
                  placeholder={t('confirmPasswordPlaceholder')}
                  value={confirmPassword}
                  onChange={(e) => setConfirmPassword(e.target.value)}
                />
              </div>
              <p className={styles.fieldFootnote}>{t('encryptionFootnote')}</p>
            </>
          )}
          {exportError && <div className={styles.errorMsg}>{exportError}</div>}
          <Button
            className={styles.submitBtn}
            onClick={handleExport}
            disabled={exporting || (includeKeys && !exportPassword)}
          >
            {exporting ? t('exporting') : t('export')}
          </Button>
        </div>

        <div className={styles.dataOverview}>
          <h3 className={styles.dataOverviewTitle}>{t('yourData')}</h3>
          <div className={styles.dataOverviewGrid}>
            <span className={styles.dataOverviewLabel}>{t('dataConversations')}</span>
            <span className={styles.dataOverviewValue}>{conversationCount}</span>
            <span className={styles.dataOverviewLabel}>{t('dataProviders')}</span>
            <span className={styles.dataOverviewValue}>{providerCount}</span>
            <span className={styles.dataOverviewLabel}>{t('dataMessages')}</span>
            <span className={styles.dataOverviewValue}>{totalMessages}</span>
          </div>
        </div>
      </div>

      <Dialog open={exportSuccess} onClose={() => setExportSuccess(false)}>
        <h2 className={styles.confirmTitle}>{t('exportComplete')}</h2>
        <p className={styles.confirmDesc}>{t('success')}</p>
        <div className={styles.confirmActions}>
          <Button size="sm" onClick={() => setExportSuccess(false)}>{tc('done')}</Button>
        </div>
      </Dialog>
    </>
  );
}
