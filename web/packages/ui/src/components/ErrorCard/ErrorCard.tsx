'use client';

import { useState } from 'react';
import styles from './ErrorCard.module.css';

interface ErrorCardProps {
  title: string;
  description: string;
  detail?: string;
  onRetry?: () => void;
}

export function ErrorCard({ title, description, detail, onRetry }: ErrorCardProps) {
  const [detailOpen, setDetailOpen] = useState(false);

  return (
    <div className={styles.card}>
      <div className={styles.header}>
        <svg className={styles.icon} width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <circle cx="12" cy="12" r="10" />
          <line x1="12" y1="8" x2="12" y2="12" />
          <line x1="12" y1="16" x2="12.01" y2="16" />
        </svg>
        <h3 className={styles.title}>{title}</h3>
      </div>
      <p className={styles.description}>{description}</p>
      {detail && (
        <div className={styles.detailWrap}>
          <button
            className={styles.detailToggle}
            onClick={() => setDetailOpen((v) => !v)}
          >
            {detailOpen ? 'Hide details' : 'Show details'}
          </button>
          {detailOpen && (
            <pre className={styles.detailContent}>{detail}</pre>
          )}
        </div>
      )}
      {onRetry && (
        <button className={styles.retryBtn} onClick={onRetry}>
          Retry
        </button>
      )}
    </div>
  );
}
