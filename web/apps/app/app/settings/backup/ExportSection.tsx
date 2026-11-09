'use client';

import { useState } from 'react';
import { useTranslations } from 'next-intl';
import { Button, Dialog } from '@oriveo/ui';
import { downloadBackupBlob, exportBackup, openBackupSaveDestination } from '../../../lib/backup';
import { useAppStore } from '../../../providers/StoreProvider';
import styles from './BackupPage.module.css';
import { BackupPasswordInput } from './BackupPasswordInput';

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

    const filename = `Oriveo-Backup-${new Date().toISOString().slice(0, 10)}.oriveo`;
    const options = {
      includeApiKeys: includeKeys,
      password: includeKeys ? exportPassword : undefined,
    };

    setExporting(true);
    setExportError('');
    setExportSuccess(false);

    try {
      // The save picker must open inside this click, before the export work; cancelling it exports nothing.
      const destination = await openBackupSaveDestination(filename);
      if (destination) {
        await exportBackup(options, destination);
      } else {
        downloadBackupBlob(await exportBackup(options), filename);
      }
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
                <BackupPasswordInput
                  placeholder={t('passwordPlaceholder')}
                  value={exportPassword}
                  onChange={(e) => setExportPassword(e.target.value)}
                />
              </div>
              <div className={styles.fieldGroup}>
                <label className={styles.fieldLabel}>{t('confirmPassword')}</label>
                <BackupPasswordInput
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
