'use client';

import { useState, useEffect, type CSSProperties, type ReactNode } from 'react';
import { useTranslations } from 'next-intl';
import { Bell, Check, Minus, X } from 'lucide-react';
import styles from './Toast.module.css';

/** Semantic style: picks the colour and glyph of the round icon; undefined means neutral. Same table as iOS ToastStyle / Android GlobalToastStyle. */
export type ToastVariant = 'success' | 'error' | 'warning' | 'info' | 'removed';
type ToastStyle = ToastVariant | 'neutral';

interface ToastMessage {
  content: ReactNode;
  onUndo?: () => void;
  variant?: ToastVariant;
  undoLabel?: string;
}

let toastTimer: ReturnType<typeof setTimeout>;
let setToastState: ((msg: ToastMessage | null) => void) | null = null;

export function showToast(
  message: string,
  duration = 3000,
  onUndo?: () => void,
  variant?: ToastVariant,
  undoLabel?: string,
) {
  if (!setToastState) {
    console.warn('ToastContainer not mounted');
    return;
  }
  clearTimeout(toastTimer);
  setToastState({ content: message, onUndo, variant, undoLabel });
  toastTimer = setTimeout(() => setToastState?.(null), duration);
}

export function showRichToast(
  content: ReactNode,
  duration = 4000,
  variant?: ToastVariant,
  onUndo?: () => void,
  undoLabel?: string,
) {
  if (!setToastState) {
    console.warn('ToastContainer not mounted');
    return;
  }
  clearTimeout(toastTimer);
  setToastState({ content, onUndo, variant, undoLabel });
  toastTimer = setTimeout(() => setToastState?.(null), duration);
}

export const TOAST_ACCENT: Record<ToastStyle, string> = {
  success: 'var(--o-success)',
  error: 'var(--o-error)',
  warning: 'var(--o-warning)',
  info: 'var(--o-info)',
  removed: 'var(--o-text-secondary)',
  neutral: 'var(--o-text-secondary)',
};

const GLYPH_SIZE = 13;
const GLYPH_STROKE = 2.75;

// lucide has no unframed "!" or "i", so these two are drawn by hand to keep the glyph centred in the round icon
function BareGlyph({ kind }: { kind: 'warning' | 'info' }) {
  return (
    <svg
      width={GLYPH_SIZE}
      height={GLYPH_SIZE}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={GLYPH_STROKE}
      strokeLinecap="round"
      aria-hidden
    >
      {kind === 'warning' ? (
        <>
          <line x1="12" y1="4" x2="12" y2="14" />
          <line x1="12" y1="20" x2="12" y2="20" />
        </>
      ) : (
        <>
          <line x1="12" y1="4" x2="12" y2="4" />
          <line x1="12" y1="10" x2="12" y2="20" />
        </>
      )}
    </svg>
  );
}

function ToastGlyph({ toastStyle }: { toastStyle: ToastStyle }) {
  const common = { size: GLYPH_SIZE, strokeWidth: GLYPH_STROKE, 'aria-hidden': true } as const;
  switch (toastStyle) {
    case 'success': return <Check {...common} />;
    case 'error': return <X {...common} />;
    case 'warning': return <BareGlyph kind="warning" />;
    case 'info': return <BareGlyph kind="info" />;
    case 'removed': return <Minus {...common} />;
    case 'neutral': return <Bell {...common} strokeWidth={2.25} fill="currentColor" />;
  }
}

export function ToastContainer() {
  const tCommon = useTranslations('common');
  const [message, setMessage] = useState<ToastMessage | null>(null);

  useEffect(() => {
    setToastState = setMessage;
    return () => {
      setToastState = null;
      clearTimeout(toastTimer);
    };
  }, []);

  const dismiss = () => {
    setMessage(null);
    clearTimeout(toastTimer);
  };

  if (!message) return null;

  const toastStyle: ToastStyle = message.variant ?? 'neutral';
  const hasAction = Boolean(message.onUndo);

  return (
    <div className={styles.host}>
      {/* Clicking the capsule dismisses it; like iOS and Android there is no persistent close button */}
      <div
        role="alert"
        className={styles.capsule}
        data-variant={toastStyle}
        data-has-action={hasAction || undefined}
        style={{ '--toast-accent': TOAST_ACCENT[toastStyle] } as CSSProperties}
        onClick={dismiss}
      >
        <span className={styles.icon} data-toast-icon={toastStyle}>
          <ToastGlyph toastStyle={toastStyle} />
        </span>
        <span className={styles.message}>{message.content}</span>
        {hasAction && (
          <>
            <span className={styles.divider} data-toast-divider aria-hidden />
            <button
              type="button"
              className={styles.action}
              onClick={(event) => {
                event.stopPropagation();
                const action = message.onUndo;
                dismiss();
                action?.();
              }}
            >
              {message.undoLabel ?? tCommon('undo')}
            </button>
          </>
        )}
      </div>
    </div>
  );
}
