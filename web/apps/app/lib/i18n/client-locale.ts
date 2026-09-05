/**
 * Locale resolution and message loading for the browser.
 *
 * next-intl's `getRequestConfig` runs on the server and therefore never runs for a statically
 * exported page. ClientIntlProvider calls into this module instead, so the locale is resolved and
 * the message bundle is imported after hydration.
 */
import { deepMerge, type MessageBag } from '@oriveo/core/i18n/merge';
import { getLocaleCookie, resolveLocale, setLocaleCookie, SUPPORTED_LOCALES, type SupportedLocale } from './locale-utils';

/** The stored preference wins; `system` (or nothing stored) falls back to navigator.language. */
export function resolveActiveLocale(): SupportedLocale {
  const cookie = getLocaleCookie();
  if (cookie && cookie !== 'system' && SUPPORTED_LOCALES.includes(cookie as SupportedLocale)) {
    return cookie as SupportedLocale;
  }
  const nav = typeof navigator !== 'undefined' ? navigator.language : '';
  return resolveLocale('system', nav);
}

/**
 * Loads one locale's messages, merged over English.
 *
 * A key that a translation has not caught up with yet renders its English text rather than the
 * raw key path, which is what next-intl would otherwise show.
 */
export async function loadMessages(locale: SupportedLocale): Promise<MessageBag> {
  const target = ((await import(`../../messages/${locale}.json`)) as { default: MessageBag }).default;
  if (locale === 'en') return target;
  const fallback = ((await import('../../messages/en.json')) as { default: MessageBag }).default;
  return deepMerge(fallback, target);
}

/** Persists the preference; the cookie is also what the server layout reads on the next load. */
export function persistLocale(locale: SupportedLocale | 'system'): void {
  setLocaleCookie(locale);
}
