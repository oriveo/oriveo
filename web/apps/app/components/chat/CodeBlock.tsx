'use client';

import { useState, useCallback, useMemo, type ReactNode } from 'react';
import { useTranslations } from 'next-intl';
import { FilePlus2 } from 'lucide-react';
import { ContextMenu, useContextMenu, type ContextMenuItem } from '../ContextMenu';
import { copyToClipboard } from '../../lib/utils/clipboard';
import styles from './CodeBlock.module.css';

interface CodeBlockProps {
  language?: string;
  /** Plain text for clipboard copy */
  plainText: string;
  /** Pre-highlighted HTML from highlight.js (used instead of children to avoid HAST issues) */
  highlightedHtml?: string;
  /** Fallback React nodes (used during streaming when highlightedHtml is not provided) */
  children?: ReactNode;
  onSaveNote?: (markdown: string) => void;
}

export function CodeBlock({ language, plainText, highlightedHtml, children, onSaveNote }: CodeBlockProps) {
  const t = useTranslations('pages.chat');
  const tCtx = useTranslations('contextMenu');
  const [copied, setCopied] = useState(false);
  const { menu, handleContextMenu: onContextMenu, closeMenu } = useContextMenu();

  const handleCopy = useCallback(async () => {
    const ok = await copyToClipboard(plainText, { failureToast: tCtx('copyFailed') });
    if (ok) {
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    }
  }, [plainText, tCtx]);

  const contextMenuItems = useMemo<ContextMenuItem[]>(
    () => [
      { label: tCtx('copyCode'), onAction: handleCopy },
      {
        label: tCtx('copyPlainText'),
        onAction: () =>
          copyToClipboard(plainText, { successToast: tCtx('copied'), failureToast: tCtx('copyFailed') }),
      },
    ],
    [tCtx, handleCopy, plainText],
  );

  const handleRightClick = useCallback(
    (e: React.MouseEvent) => onContextMenu(e, contextMenuItems),
    [onContextMenu, contextMenuItems],
  );

  return (
    <div className={styles.wrapper} onContextMenu={handleRightClick}>
      <div className={styles.header}>
        {language && <span className={styles.language}>{language}</span>}
        <div className={styles.headerActions}>
          <button
            type="button"
            className={styles.copyBtn}
            onClick={handleCopy}
            aria-label={t('copyCode')}
          >
            {copied ? (
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <polyline points="20 6 9 17 4 12" />
              </svg>
            ) : (
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
                <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
              </svg>
            )}
          </button>
          {onSaveNote && (
            <button
              type="button"
              className={styles.copyBtn}
              onClick={() => onSaveNote(`\`\`\`${language ?? ''}\n${plainText}\n\`\`\``)}
              aria-label={t('saveAsNote')}
              title={t('saveAsNote')}
            >
              <FilePlus2 size={14} aria-hidden />
              <span className={styles.buttonLabel}>{t('saveAsNote')}</span>
            </button>
          )}
        </div>
      </div>
      <div className={styles.codeArea}>
        <pre className={styles.pre} data-quote-block="code">
          {highlightedHtml ? (
            <code
              className={language ? `hljs language-${language}` : 'hljs'}
              dangerouslySetInnerHTML={{ __html: highlightedHtml }}
            />
          ) : (
            <code className={language ? `hljs language-${language}` : 'hljs'}>
              {plainText || children}
            </code>
          )}
        </pre>
      </div>
      {menu && (
        <ContextMenu items={menu.items} position={menu.position} onClose={closeMenu} />
      )}
    </div>
  );
}
