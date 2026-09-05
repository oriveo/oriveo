'use client';

import { useTranslations } from 'next-intl';
import type { ImportResult } from '../../../lib/backup';
import styles from './BackupPage.module.css';

const COUNT_ROWS: { key: keyof ImportResult; label: string }[] = [
  { key: 'conversationsImported', label: 'resultConversationsAdded' },
  { key: 'conversationsMerged', label: 'resultConversationsMerged' },
  { key: 'conversationsSkipped', label: 'resultConversationsSkipped' },
  { key: 'providersImported', label: 'resultProvidersAdded' },
  { key: 'providersMerged', label: 'resultProvidersMerged' },
  { key: 'providersSkipped', label: 'resultProvidersSkipped' },
  { key: 'skillsImported', label: 'resultSkillsAdded' },
  { key: 'skillsMerged', label: 'resultSkillsMerged' },
  { key: 'skillsSkipped', label: 'resultSkillsSkipped' },
  { key: 'keysRestored', label: 'resultKeysRestored' },
  { key: 'imagesRestored', label: 'resultImagesRestored' },
];

const BOOL_ROWS: { key: keyof ImportResult; label: string }[] = [
  { key: 'restoredPreferences', label: 'resultPreferencesRestored' },
  { key: 'restoredLastUsedModel', label: 'resultLastUsedModelRestored' },
];

export function ImportResultCard({ result }: { result: ImportResult }) {
  const t = useTranslations('pages.backup');

  return (
    <div className={styles.resultCard}>
      <h3 className={styles.resultTitle}>{t('importComplete')}</h3>
      {COUNT_ROWS.filter((row) => (result[row.key] as number) > 0).map((row) => (
        <div key={row.key} className={styles.resultRow}>
          <span>{t(row.label)}</span>
          <span className={styles.resultValue}>{result[row.key] as number}</span>
        </div>
      ))}
      {BOOL_ROWS.filter((row) => result[row.key] === true).map((row) => (
        <div key={row.key} className={styles.resultRow}>
          <span>{t(row.label)}</span>
          <span className={styles.resultValue}>✓</span>
        </div>
      ))}
      {result.skillsRequiringKnowledgeReupload > 0 && (
        <p className={styles.resultHint}>{t('knowledgeReuploadNotice')}</p>
      )}
    </div>
  );
}

export function formatBackupDate(iso: string): string {
  try {
    return new Date(iso).toLocaleDateString(undefined, {
      year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit',
    });
  } catch {
    return iso;
  }
}
