'use client';

import { type ReactNode, useEffect } from 'react';
import { usePathname } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { AppShellWrapper } from './AppShellWrapper';
import { ServiceReachabilityBanner } from './ServiceReachabilityBanner';
import { showToast, ToastContainer } from './Toast';
import { recordGenerationParameterDiagnostic } from '../lib/core/chat/generation-parameter-diagnostics';

// Routes with no sidebar: welcome and the root redirect are full-screen.
// providers/new, providers/relay/new and manual-model are not in this list, because their
// real entry points (ProviderList, Skills, Chat) already render inside the shell and
// suddenly losing the sidebar on navigation would break the flow.
function isPlainRoute(pathname: string): boolean {
  if (pathname === '/' || pathname === '/welcome') return true;
  return false;
}

/**
 * Keeps AppShellWrapper mounted inside the root layout, so React reuses the same subtree
 * when navigating between shell routes and the sidebar / ConversationList stay mounted.
 */
export function PersistentShellLayout({ children }: { children: ReactNode }) {
  const pathname = usePathname() ?? '/';
  const tCommon = useTranslations('common');

  useEffect(() => {
    const notifyRecovered = (event: Event) => {
      const detail = (event as CustomEvent<{ param?: unknown; transport?: unknown; modelId?: unknown }>).detail;
      const param = detail?.param;
      if (typeof param !== 'string') return;
      recordGenerationParameterDiagnostic({
        parameter: param,
        status: 'recovered',
        transport: typeof detail.transport === 'string' ? detail.transport : 'unknown',
        errorClass: 'unsupported_parameter',
        phase: 'before_first_token',
        ...(typeof detail.modelId === 'string' ? { modelId: detail.modelId } : {}),
      });
      showToast(tCommon('generationParameterSelfHealed', { param }), 5000, undefined, 'warning');
    };
    window.addEventListener('oriveo:unsupported-param-self-healed', notifyRecovered);
    return () => window.removeEventListener('oriveo:unsupported-param-self-healed', notifyRecovered);
  }, [tCommon]);

  if (isPlainRoute(pathname)) {
    return (
      <>
        {children}
        <ToastContainer />
        <ServiceReachabilityBanner />
      </>
    );
  }

  return <AppShellWrapper>{children}</AppShellWrapper>;
}
