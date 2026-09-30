'use client';

import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { BackButton } from '@oriveo/ui';
import { ExportSection } from './ExportSection';
import { ImportSection } from './ImportSection';
import styles from './BackupPage.module.css';

export function BackupPage() {
  const t = useTranslations('pages.backup');
  const tc = useTranslations('common');
  const router = useRouter();

  return (
    <div className={styles.page}>
      <BackButton className={styles.backLink} label={tc('back')} onClick={() => router.push('/settings')} />

      <div className={styles.header}>
        <h1 className={styles.title}>{t('title')}</h1>
      </div>

      <ExportSection />
      <ImportSection />
    </div>
  );
}
