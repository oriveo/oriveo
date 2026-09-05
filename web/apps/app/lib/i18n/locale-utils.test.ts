import { describe, expect, it } from 'vitest';
import { isRTL, resolveLocale, SUPPORTED_LOCALES } from './locale-utils';

describe('locale-utils', () => {
  it('exposes the six newly added locales in the supported locale contract', () => {
    expect(SUPPORTED_LOCALES).toEqual(expect.arrayContaining([
      'hi',
      'id',
      'vi',
      'th',
      'tr',
      'ru',
    ]));
    expect(SUPPORTED_LOCALES).toHaveLength(16);
  });

  it('resolves the new locale tags from Accept-Language headers', () => {
    expect(resolveLocale('system', 'hi-IN,hi;q=0.9,en;q=0.8')).toBe('hi');
    expect(resolveLocale('system', 'id-ID,id;q=0.9,en;q=0.8')).toBe('id');
    expect(resolveLocale('system', 'vi-VN,vi;q=0.9,en;q=0.8')).toBe('vi');
    expect(resolveLocale('system', 'th-TH,th;q=0.9,en;q=0.8')).toBe('th');
    expect(resolveLocale('system', 'tr-TR,tr;q=0.9,en;q=0.8')).toBe('tr');
    expect(resolveLocale('system', 'ru-RU,ru;q=0.9,en;q=0.8')).toBe('ru');
  });

  it('keeps RTL restricted to Arabic while the new locales remain LTR', () => {
    expect(isRTL('ar')).toBe(true);
    expect(isRTL('hi')).toBe(false);
    expect(isRTL('id')).toBe(false);
    expect(isRTL('vi')).toBe(false);
    expect(isRTL('th')).toBe(false);
    expect(isRTL('tr')).toBe(false);
    expect(isRTL('ru')).toBe(false);
  });
});
