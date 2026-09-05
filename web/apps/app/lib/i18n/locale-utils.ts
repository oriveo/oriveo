/**
 * Locale   @oriveo/core/i18n/locale A02 §3.3 Web +   import  
 *  cookie   document  renderer 
 */
import type { SupportedLocale } from '@oriveo/core/i18n/locale';

export { SUPPORTED_LOCALES, isRTL, resolveLocale } from '@oriveo/core/i18n/locale';
export type { SupportedLocale } from '@oriveo/core/i18n/locale';

export function setLocaleCookie(locale: SupportedLocale | 'system'): void {
  if (typeof document === 'undefined') return;
  document.cookie = `NEXT_LOCALE=${locale};path=/;max-age=31536000;SameSite=Lax`;
}

export function getLocaleCookie(): string | undefined {
  if (typeof document === 'undefined') return undefined;
  const match = document.cookie.match(/(?:^|;\s*)NEXT_LOCALE=([^;]*)/);
  return match?.[1];
}
