'use client';

import { useState, useEffect } from 'react';
import { useTranslations } from 'next-intl';
import { consumeChunkReloadAttempt, isChunkLoadError } from '../lib/sentry/ignore-browser-noise';

interface ErrorProps {
  error: Error & { digest?: string };
  reset: () => void;
}

export default function ErrorPage({ error, reset }: ErrorProps) {
  const t = useTranslations('errorBoundary');
  const [showDetail, setShowDetail] = useState(false);

  useEffect(() => {
    // Stale chunk (an older client referencing a hash that has since been replaced): reset() cannot
    // recover a missing chunk, so a hard reload is required. At most once per session, gated by
    // sessionStorage to avoid a reload loop.
    if (typeof window !== 'undefined' && isChunkLoadError(error)) {
      if (consumeChunkReloadAttempt(window.sessionStorage)) {
        window.location.reload();
        return;
      }
    }
    console.error('[ErrorBoundary]', error);
  }, [error]);

  return (
    <div style={{
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      minHeight: '100vh',
      padding: '24px',
    }}>
      <div style={{
        maxWidth: 440,
        width: '100%',
        textAlign: 'center',
      }}>
        {/* Error icon */}
        <div style={{ marginBottom: 24 }}>
          <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="var(--o-error, #ef4444)" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
            <circle cx="12" cy="12" r="10" />
            <line x1="12" y1="8" x2="12" y2="12" />
            <line x1="12" y1="16" x2="12.01" y2="16" />
          </svg>
        </div>

        <h1 style={{
          fontSize: 'var(--o-text-xl, 20px)',
          fontWeight: 700,
          color: 'var(--o-text, #111)',
          margin: '0 0 8px',
        }}>
          {t('title')}
        </h1>

        <p style={{
          fontSize: 'var(--o-text-sm, 14px)',
          color: 'var(--o-text-secondary, #666)',
          margin: '0 0 24px',
          lineHeight: 1.5,
        }}>
          {t('description')}
        </p>

        {/* Primary actions */}
        <div style={{ display: 'flex', gap: 12, justifyContent: 'center', flexWrap: 'wrap' }}>
          <button
            onClick={reset}
            style={{
              padding: '10px 24px',
              borderRadius: 'var(--o-radius-md, 8px)',
              border: 'none',
              background: 'var(--o-primary, #8B5CF6)',
              color: '#fff',
              fontSize: 'var(--o-text-sm, 14px)',
              fontWeight: 600,
              cursor: 'pointer',
            }}
          >
            {t('retry')}
          </button>
          <a
            href="/chat"
            style={{
              padding: '10px 24px',
              borderRadius: 'var(--o-radius-md, 8px)',
              border: '1px solid var(--o-border, #e5e7eb)',
              background: 'transparent',
              color: 'var(--o-text, #111)',
              fontSize: 'var(--o-text-sm, 14px)',
              fontWeight: 600,
              textDecoration: 'none',
              display: 'inline-flex',
              alignItems: 'center',
            }}
          >
            {t('goHome')}
          </a>
        </div>

        {/* Collapsible technical details */}
        {error.message && (
          <div style={{ marginTop: 32, textAlign: 'start' }}>
            <button
              onClick={() => setShowDetail((v) => !v)}
              style={{
                background: 'none',
                border: 'none',
                color: 'var(--o-text-tertiary, #999)',
                fontSize: 'var(--o-text-xs, 12px)',
                cursor: 'pointer',
                padding: 0,
                display: 'flex',
                alignItems: 'center',
                gap: 4,
              }}
            >
              <svg
                width="12"
                height="12"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                style={{
                  transform: showDetail ? 'rotate(90deg)' : 'rotate(0deg)',
                  transition: 'transform 150ms',
                }}
              >
                <polyline points="9 18 15 12 9 6" />
              </svg>
              {t('technicalDetails')}
            </button>
            {showDetail && (
              <pre style={{
                marginTop: 8,
                padding: 12,
                background: 'var(--o-surface, #f9fafb)',
                border: '1px solid var(--o-border, #e5e7eb)',
                borderRadius: 'var(--o-radius-sm, 6px)',
                fontSize: 12,
                color: 'var(--o-text-secondary, #666)',
                whiteSpace: 'pre-wrap',
                wordBreak: 'break-word',
                maxHeight: 200,
                overflow: 'auto',
              }}>
                {error.message}
                {error.digest && `\n\nDigest: ${error.digest}`}
              </pre>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
