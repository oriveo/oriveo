'use client';

/**
 * Client-side i18n provider: the counterpart to the server `getMessages` in layout.tsx.
 * The static-export renderer uses it to resolve the locale in the browser and dynamically
 * import the message bundle.
 */
import { NextIntlClientProvider } from 'next-intl';
import { useEffect, useState, type ReactNode } from 'react';
import type { MessageBag } from '@oriveo/core/i18n/merge';
import { isRTL } from '../../lib/i18n/locale-utils';
import { loadMessages, resolveActiveLocale } from '../../lib/i18n/client-locale';

interface IntlState {
  locale: string;
  messages: MessageBag;
}

export function ClientIntlProvider({ children }: { children: ReactNode }): React.JSX.Element | null {
  const [state, setState] = useState<IntlState | null>(null);

  useEffect(() => {
    let cancelled = false;
    const locale = resolveActiveLocale();
    document.documentElement.lang = locale;
    document.documentElement.dir = isRTL(locale) ? 'rtl' : 'ltr';

    loadMessages(locale)
      .then((messages) => {
        if (!cancelled) setState({ locale, messages });
      })
      .catch(() => {
        //   →  
        document.documentElement.lang = 'en';
        document.documentElement.dir = 'ltr';
        void loadMessages('en').then((messages) => {
          if (!cancelled) setState({ locale: 'en', messages });
        });
      });

    return () => {
      cancelled = true;
    };
  }, []);

  if (!state) return null;

  return (
    <NextIntlClientProvider locale={state.locale} messages={state.messages}>
      {children}
    </NextIntlClientProvider>
  );
}
