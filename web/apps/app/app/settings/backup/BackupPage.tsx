'use client';

import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { ArrowLeft } from 'lucide-react';
import { ExportSection } from './ExportSection';
import { ImportSection } from './ImportSection';
import styles from './BackupPage.module.css';

export function BackupPage() {
  const t = useTranslations('pages.backup');
  const router = useRouter();

  return (
    <div className={styles.page}>
      <span
        className={styles.backLink}
        onClick={() => router.push('/settings')}
        role="button"
        tabIndex={0}
        onKeyDown={(e) => e.key === 'Enter' && router.push('/settings')}
      >
        <ArrowLeft size={14} />
        {t('title')}
      </span>

      <div className={styles.header}>
        <h1 className={styles.title}>{t('title')}</h1>
      </div>

      <ExportSection />
      <ImportSection />
    </div>
  );
}
