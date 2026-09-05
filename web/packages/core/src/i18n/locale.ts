/**
 * Locale vocabulary and resolution, with no runtime dependency of its own.
 *
 * Reading and writing the stored preference needs `document`, so it lives in the app package
 * (lib/i18n/locale-utils.ts) rather than here.
 */
import type { LanguageOption } from '@oriveo/shared/pure-types';

export const SUPPORTED_LOCALES = [
  'en', 'zh-Hans', 'zh-Hant', 'ja', 'ko', 'es', 'fr', 'de', 'pt-BR', 'ar', 'hi', 'id', 'vi', 'th', 'tr', 'ru',
] as const;

export type SupportedLocale = (typeof SUPPORTED_LOCALES)[number];

const RTL_LOCALES: SupportedLocale[] = ['ar'];

export function isRTL(locale: string): boolean {
  return RTL_LOCALES.includes(locale as SupportedLocale);
}

export function resolveLocale(
  preference: LanguageOption,
  acceptLanguage?: string,
): SupportedLocale {
  if (preference !== 'system' && SUPPORTED_LOCALES.includes(preference as SupportedLocale)) {
    return preference as SupportedLocale;
  }

  // Resolve from Accept-Language header
  if (acceptLanguage) {
    const langs = acceptLanguage
      .split(',')
      .map((part) => part.split(';')[0].trim());

    for (const lang of langs) {
      // Exact match
      if (SUPPORTED_LOCALES.includes(lang as SupportedLocale)) {
        return lang as SupportedLocale;
      }
      // Prefix match (e.g., "zh-CN" → "zh-Hans", "pt" → "pt-BR")
      const prefix = lang.split('-')[0];
      if (prefix === 'zh') {
        if (lang.includes('TW') || lang.includes('Hant') || lang.includes('HK')) {
          return 'zh-Hant';
        }
        return 'zh-Hans';
      }
      if (prefix === 'pt') return 'pt-BR';
      const match = SUPPORTED_LOCALES.find((l) => l.startsWith(prefix));
      if (match) return match;
    }
  }

  return 'en';
}
