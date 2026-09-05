import { describe, expect, it } from 'vitest';
import { isValidProviderKind, type LanguageOption } from './enums';

describe('LanguageOption', () => {
  it('includes the full locale expansion contract shared across clients', () => {
    const values: LanguageOption[] = [
      'system',
      'en',
      'zh-Hans',
      'zh-Hant',
      'ja',
      'ko',
      'es',
      'fr',
      'de',
      'pt-BR',
      'ar',
      'hi',
      'id',
      'vi',
      'th',
      'tr',
      'ru',
    ];

    expect(values).toHaveLength(17);
    expect(values.slice(-6)).toEqual(['hi', 'id', 'vi', 'th', 'tr', 'ru']);
  });
});

describe('ProviderKind', () => {
  it('includes deepseek in the shared provider contract', () => {
    expect(isValidProviderKind('deepseek')).toBe(true);
  });

  it('includes moonshot/Kimi in the shared provider contract', () => {
    expect(isValidProviderKind('moonshot')).toBe(true);
  });

  it('includes openAI in the shared provider contract', () => {
    expect(isValidProviderKind('openAI')).toBe(true);
  });
});
