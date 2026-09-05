'use client';

import { useState, useEffect, type ReactNode } from 'react';
import { useTranslations } from 'next-intl';
import { CheckCircle2, XCircle, AlertTriangle } from 'lucide-react';

type ToastVariant = 'success' | 'error' | 'warning';

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

// Semantic colours: green for success, red for error, yellow for warning
const VARIANT_ACCENT: Record<ToastVariant, string> = {
  success: 'var(--o-success)',
  error: 'var(--o-error)',
  warning: 'var(--o-warning)',
};

function VariantIcon({ variant }: { variant: ToastVariant }) {
  const color = VARIANT_ACCENT[variant];
  if (variant === 'success') return <CheckCircle2 size={16} color={color} aria-hidden />;
  if (variant === 'error') return <XCircle size={16} color={color} aria-hidden />;
  return <AlertTriangle size={16} color={color} aria-hidden />;
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

  const handleUndo = () => {
    message?.onUndo?.();
    setMessage(null);
    clearTimeout(toastTimer);
  };

  if (!message) return null;

  const accent = message.variant ? VARIANT_ACCENT[message.variant] : undefined;

  return (
    <div role="alert" style={{
      position: 'fixed',
      top: 'var(--o-space-lg)',
      right: 'var(--o-space-lg)',
      zIndex: 10000,
      display: 'flex',
      alignItems: 'center',
      gap: 'var(--o-space-sm)',
      padding: 'var(--o-space-sm) var(--o-space-md)',
      background: accent
        ? `color-mix(in srgb, ${accent} 12%, var(--o-surface-overlay))`
        : 'var(--o-surface-overlay)',
      backdropFilter: 'blur(12px)',
      WebkitBackdropFilter: 'blur(12px)',
      border: `1px solid ${accent ? `color-mix(in srgb, ${accent} 28%, transparent)` : 'var(--o-border)'}`,
      borderRadius: 'var(--o-radius-md)',
      boxShadow: 'var(--o-elevation-modal)',
      fontSize: 'var(--o-text-sm)',
      color: 'var(--o-text)',
      animation: 'toastIn 200ms ease-out',
    }}>
      <style>{`@keyframes toastIn { from { opacity: 0; transform: translateY(-8px); } to { opacity: 1; transform: translateY(0); } }`}</style>
      {message.variant && <VariantIcon variant={message.variant} />}
      <span>{message.content}</span>
      {message.onUndo && (
        <button
          type="button"
          onClick={handleUndo}
          style={{
            background: 'var(--o-primary)',
            border: 'none',
            cursor: 'pointer',
            color: 'white',
            padding: '4px 8px',
            borderRadius: '4px',
            fontSize: '12px',
            fontWeight: 500,
          }}
        >
          {message.undoLabel ?? tCommon('undo')}
        </button>
      )}
      <button
        type="button"
        onClick={() => setMessage(null)}
        aria-label={tCommon('close')}
        style={{
          background: 'none', border: 'none', cursor: 'pointer',
          color: 'var(--o-text-tertiary)', padding: 2, display: 'flex',
        }}
      >
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" />
        </svg>
      </button>
    </div>
  );
}
