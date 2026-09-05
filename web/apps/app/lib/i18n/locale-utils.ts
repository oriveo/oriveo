/**
 * Browser-side locale helpers.
 *
 * The pure parts (SUPPORTED_LOCALES, isRTL, resolveLocale) are re-exported from @oriveo/core so
 * that app code has a single import site for locale handling. The cookie helpers stay here
 * because they touch `document`, which @oriveo/core is not allowed to reach.
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
