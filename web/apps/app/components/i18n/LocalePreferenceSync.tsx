'use client';

/**
 * Keeps the interface language in sync with the stored language preference.
 *
 * The interface language comes from the `NEXT_LOCALE` cookie - that is the only thing SSR's
 * `getLocale()` reads - while the dropdown on the settings page shows `preferences.language`
 * from the store. The two are only written together when the user picks an entry, so any write
 * that does **not** go through that dropdown makes them diverge: the preference becomes
 * `zh-Hans` while the cookie stays English, the dropdown reads "Simplified Chinese", the
 * interface stays English, and the user cannot fix it by clicking - the entry they want is
 * already selected, so `onChange` never fires.
 *
 * This converges on a single exit instead of patching every write site: preferences also arrive
 * through hydration and backup import, and patching them one by one brings the same bug back in
 * another shape as soon as one path is missed.
 *
 * `system` is excluded: it means "follow the browser", so the cookie stays `system` and
 * negotiation decides.
 */
import { useEffect, useRef } from 'react';
import { useRouter } from 'next/navigation';
import { useAppStore } from '../../providers/StoreProvider';
import { getLocaleCookie, setLocaleCookie, SUPPORTED_LOCALES, type SupportedLocale } from '../../lib/i18n/locale-utils';

export function LocalePreferenceSync(): null {
  //   layout   mock   store   layout  
  //   preferences  
  const language = useAppStore((s) => s.preferences?.language);
  const router = useRouter();
  //  cookie  document.cookie  
  //   refresh   effect   cookie   refresh 
  const appliedRef = useRef<string | null>(null);

  useEffect(() => {
    if (!language || language === 'system') return;
    if (!SUPPORTED_LOCALES.includes(language as SupportedLocale)) return;
    if (appliedRef.current === language) return;
    if (getLocaleCookie() === language) {
      appliedRef.current = language;
      return;
    }
    appliedRef.current = language;
    setLocaleCookie(language as SupportedLocale);
    // SSR   messages refresh  
    router.refresh();
  }, [language, router]);

  return null;
}
