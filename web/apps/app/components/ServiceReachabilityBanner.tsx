'use client';

import { useEffect, type CSSProperties, type ReactNode } from 'react';
import { useTranslations } from 'next-intl';
import { X, WifiOff } from 'lucide-react';
import { useServiceReachabilityBanner } from '../lib/hooks/useServiceReachability';
import { serviceReachabilityMonitor } from '../lib/core/reachability/service-reachability-monitor';

/**
 * Persistent service reachability banner at the top of the screen.
 *
 * - Shows and hides itself from the `serviceReachabilityMonitor` state.
 * - Only reports a system-level loss of connectivity; remote service flakiness is reported in place
 *   by the page or action that hit it, so returning to the foreground does not nag repeatedly.
 * - Visuals: rounded card with a leading icon and the copy, coloured from --o-error / --o-warning /
 *   --o-success.
 *
 * Startup: the component calls monitor.start() on mount; the monitor deduplicates internally, so
 * mounting more than once is safe.
 */
export function ServiceReachabilityBanner() {
  const state = useServiceReachabilityBanner();
  const t = useTranslations('reachability');

  useEffect(() => {
    serviceReachabilityMonitor.start();
  }, []);

  if (state === 'online') return null;

  const model = bannerModel(state, t);
  if (!model) return null;

  return (
    <div
      role="status"
      aria-live="polite"
      style={{
        position: 'fixed',
        top: 'var(--o-space-sm)',
        left: '50%',
        transform: 'translateX(-50%)',
        // Above ToastContainer (10000) - the banner is a higher-priority system-level status message.
        zIndex: 10010,
        maxWidth: 'calc(100vw - 32px)',
        display: 'flex',
        alignItems: 'center',
        gap: 'var(--o-space-sm)',
        padding: 'var(--o-space-sm) var(--o-space-md)',
        background: model.background,
        border: `1px solid ${model.border}`,
        borderRadius: 'var(--o-radius-card)',
        boxShadow: 'var(--o-elevation-card)',
        backdropFilter: 'blur(12px)',
        WebkitBackdropFilter: 'blur(12px)',
        fontSize: 'var(--o-text-sm)',
        color: 'var(--o-text)',
        animation: 'reachabilityBannerIn 200ms ease-out',
      }}
    >
      <style>{`@keyframes reachabilityBannerIn { from { opacity: 0; transform: translate(-50%, -8px); } to { opacity: 1; transform: translate(-50%, 0); } }`}</style>
      <span aria-hidden="true" style={{ color: model.foreground, display: 'flex', alignItems: 'center' }}>
        {model.icon}
      </span>
      <span style={{ lineHeight: 1.35 }}>{model.text}</span>
      {model.dismissible && (
        <button
          type="button"
          aria-label={t('close')}
          onClick={() => serviceReachabilityMonitor.dismissCurrentBanner()}
          style={{
            width: 28,
            height: 28,
            border: 0,
            borderRadius: 999,
            background: 'transparent',
            color: model.foreground,
            display: 'inline-flex',
            alignItems: 'center',
            justifyContent: 'center',
            cursor: 'pointer',
            padding: 0,
          }}
        >
          <X size={14} strokeWidth={2.4} aria-hidden="true" />
        </button>
      )}
    </div>
  );
}

interface BannerModel {
  icon: ReactNode;
  text: string;
  foreground: CSSProperties['color'];
  background: CSSProperties['background'];
  border: CSSProperties['borderColor'];
  dismissible: boolean;
}

function bannerModel(
  state: Exclude<ReturnType<typeof useServiceReachabilityBanner>, 'online'>,
  t: (key: string) => string,
): BannerModel | null {
  switch (state) {
    case 'noNetwork':
      return {
        icon: <WifiOff size={16} strokeWidth={2.25} />,
        text: t('noNetwork'),
        foreground: 'var(--o-error)',
        background: 'var(--o-error-subtle)',
        border: 'var(--o-error)',
        dismissible: true,
      };
    case 'servicesUnreachable':
      return null;
    default:
      return null;
  }
}
