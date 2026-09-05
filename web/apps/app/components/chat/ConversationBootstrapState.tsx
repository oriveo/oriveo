'use client';

import { useTranslations } from 'next-intl';
import styles from './ConversationBootstrapState.module.css';

// Mimic the rhythm of a real conversation: long assistant turns, short user turns, alternating.
const bootstrapBubbles = [
  { role: 'assistant', width: '62%', lines: ['74%', '94%', '58%'] },
  { role: 'user', width: '44%', lines: ['86%', '52%'] },
  { role: 'assistant', width: '70%', lines: ['90%', '66%', '82%', '40%'] },
  { role: 'user', width: '38%', lines: ['72%'] },
  { role: 'assistant', width: '54%', lines: ['82%', '58%'] },
  { role: 'user', width: '48%', lines: ['68%', '44%'] },
] as const;

export function ConversationBootstrapState() {
  const t = useTranslations('pages.chat');

  return (
    <div className={styles.state} data-testid="conversation-bootstrap-state">
      {/*
         A bare bubble skeleton has no words at all, so users read it as "this conversation
         is empty" rather than "still loading", which is where accidental deletion starts.
         This line is the only "still loading" signal, so it must not be aria-hidden.
      */}
      <p className={styles.status} role="status" aria-live="polite">
        <span className={styles.spinner} aria-hidden="true" />
        {t('conversationLoading')}
      </p>
      {bootstrapBubbles.map((bubble, index) => (
        <div
          key={index}
          className={`${styles.row} ${bubble.role === 'user' ? styles.rowRight : styles.rowLeft}`}
          aria-hidden="true"
        >
          <div
            className={`${styles.bubble} ${bubble.role === 'user' ? styles.bubbleUser : styles.bubbleAssistant}`}
            style={{ width: bubble.width }}
          >
            {bubble.lines.map((width, lineIndex) => (
              <span
                key={lineIndex}
                className={styles.line}
                style={{ width, animationDelay: `${(index * 0.08 + lineIndex * 0.05).toFixed(2)}s` }}
              />
            ))}
          </div>
        </div>
      ))}
    </div>
  );
}
