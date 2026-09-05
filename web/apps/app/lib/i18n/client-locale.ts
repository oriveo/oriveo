/**
 *   locale   +  A02 §3.3 
 *
 * static export  i18n/request.ts   getRequestConfig   renderer  
 *   locale   import   ClientIntlProvider  
 *   renderer Chromium  navigator/document.cookie  Web  
 * main   locale  window.oriveoDesktop  cookie/navigator 
 */
import { deepMerge, type MessageBag } from '@oriveo/core/i18n/merge';
import { getLocaleCookie, resolveLocale, setLocaleCookie, SUPPORTED_LOCALES, type SupportedLocale } from './locale-utils';

/**   locale cookie   navigator.language   */
export function resolveActiveLocale(): SupportedLocale {
  const cookie = getLocaleCookie();
  if (cookie && cookie !== 'system' && SUPPORTED_LOCALES.includes(cookie as SupportedLocale)) {
    return cookie as SupportedLocale;
  }
  const nav = typeof navigator !== 'undefined' ? navigator.language : '';
  return resolveLocale('system', nav);
}

/**   +   fallback  en   */
export async function loadMessages(locale: SupportedLocale): Promise<MessageBag> {
  const target = ((await import(`../../messages/${locale}.json`)) as { default: MessageBag }).default;
  if (locale === 'en') return target;
  const fallback = ((await import('../../messages/en.json')) as { default: MessageBag }).default;
  return deepMerge(fallback, target);
}

/**  Web cookie  bridge  */
export function persistLocale(locale: SupportedLocale | 'system'): void {
  setLocaleCookie(locale);
}
