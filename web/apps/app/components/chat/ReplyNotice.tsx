'use client';

import { useTranslations } from 'next-intl';
import { Play } from 'lucide-react';
import type { ReplyNotice as ReplyNoticeModel } from '../../lib/core/chat/context-visibility/reply-notice';
import styles from './ReplyNotice.module.css';

interface ReplyNoticeProps {
  notice: ReplyNoticeModel;
  onContinue?: () => void;
}

/** Incomplete / filtered answer line shown above the assistant meta row. */
export function ReplyNotice({ notice, onContinue }: ReplyNoticeProps) {
  const t = useTranslations('pages.chat');
  return (
    <div className={styles.row} data-testid="reply-notice" data-notice={notice.key}>
      <span className={notice.tone === 'secondary' ? styles.secondary : styles.warning}>
        {t(`replyNotice.${notice.key}`)}
      </span>
      {notice.showContinue && onContinue && (
        <button type="button" className={styles.continueBtn} onClick={onContinue}>
          <Play size={12} fill="currentColor" aria-hidden="true" />
          {t('recovery.continueBtn')}
        </button>
      )}
    </div>
  );
}
