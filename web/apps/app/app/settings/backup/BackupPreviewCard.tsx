'use client';

import { useTranslations } from 'next-intl';
import type { ImportPreview } from '../../../lib/backup';
import { formatBackupDate } from './ImportResultCard';
import styles from './BackupPage.module.css';

export function BackupPreviewCard({ preview }: { preview: ImportPreview }) {
  const t = useTranslations('pages.backup');

  return (
    <div className={styles.previewCard}>
      <h3 className={styles.previewTitle}>{t('previewBackupInfo')}</h3>
      <div className={styles.previewGrid}>
        <span className={styles.previewLabel}>{t('previewCreatedAt')}</span>
        <span className={styles.previewValue}>{formatBackupDate(preview.backupFile.createdAt)}</span>
        <span className={styles.previewLabel}>{t('previewPlatform')}</span>
        <span className={styles.previewValue}>{preview.backupFile.platform}</span>
        <span className={styles.previewLabel}>{t('previewVersion')}</span>
        <span className={styles.previewValue}>v{preview.backupFile.appVersion}</span>
        <span className={styles.previewLabel}>{t('previewContainsKeys')}</span>
        <span className={styles.previewValue}>{preview.backupFile.containsKeys ? t('previewYes') : t('previewNo')}</span>
      </div>
      <div className={styles.previewDivider} />
      <h3 className={styles.previewTitle}>{t('previewDataContent')}</h3>
      <div className={styles.previewGrid}>
        <span className={styles.previewLabel}>{t('previewConversations')}</span>
        <span className={styles.previewValue}>
          {t('previewCountWithExisting', { total: preview.totalConversations, existing: preview.existingConversationCount })}
        </span>
        <span className={styles.previewLabel}>{t('previewProviders')}</span>
        <span className={styles.previewValue}>
          {t('previewCountWithExisting', { total: preview.totalProviders, existing: preview.existingProviderCount })}
        </span>
        {preview.hasImages && (
          <>
            <span className={styles.previewLabel}>{t('previewImages')}</span>
            <span className={styles.previewValue}>{t('previewYes')}</span>
          </>
        )}
      </div>
    </div>
  );
}
