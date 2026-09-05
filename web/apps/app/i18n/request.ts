import { getRequestConfig } from 'next-intl/server';
import { cookies, headers } from 'next/headers';
import { deepMerge, type MessageBag } from '@oriveo/core/i18n/merge';
import { resolveLocale, SUPPORTED_LOCALES, type SupportedLocale } from '../lib/i18n/locale-utils';

export default getRequestConfig(async () => {
  const cookieStore = await cookies();
  const headerStore = await headers();

  const cookieLocale = cookieStore.get('NEXT_LOCALE')?.value ?? 'system';
  const acceptLanguage = headerStore.get('accept-language') ?? '';

  let locale: SupportedLocale;
  if (cookieLocale !== 'system' && SUPPORTED_LOCALES.includes(cookieLocale as SupportedLocale)) {
    locale = cookieLocale as SupportedLocale;
  } else {
    locale = resolveLocale('system', acceptLanguage);
  }

  const targetMessages = (await import(`../messages/${locale}.json`)).default as MessageBag;
  if (locale === 'en') {
    return { locale, messages: targetMessages };
  }
  const fallbackMessages = (await import('../messages/en.json')).default as MessageBag;
  return {
    locale,
    messages: deepMerge(fallbackMessages, targetMessages),
  };
});
