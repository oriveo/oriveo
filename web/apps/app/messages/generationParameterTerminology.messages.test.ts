import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

// In the generation parameter panel, a token is an LLM token, not a game chip or a notification code.
// Literal translations crept in before: ru "жетон" (a chip), vi "mã thông báo" (a notification code), tr "jeton" /
// "belirteç", fr "jeton", and the Chinese words for an access token or a linguistic lexeme. None of them match
// how the rest of each locale writes token.
const FORBIDDEN: Record<string, string[]> = {
  ru: ['жетон'],
  tr: ['jeton', 'belirteç'],
  vi: ['mã thông báo'],
  fr: ['jeton'],
  'zh-Hans': ['\u4ee4\u724c', '\u8bcd\u5143'],
  'zh-Hant': ['\u6b0a\u6756', '\u8a5e\u5143'],
};

function isParameterPanelKey(key: string): boolean {
  return (
    key.startsWith('generationParameter') ||
    key.startsWith('generationGroup') ||
    key === 'capabilityControlAdvancedSettingsSubtitle'
  );
}

describe('generation parameter token terminology', () => {
  it('does not translate token literally in the parameter panel', () => {
    const problems: string[] = [];
    let scanned = 0;
    for (const [locale, words] of Object.entries(FORBIDDEN)) {
      const messages = JSON.parse(readFileSync(join(process.cwd(), 'messages', `${locale}.json`), 'utf8'));
      for (const [key, value] of Object.entries(messages.common as Record<string, unknown>)) {
        if (!isParameterPanelKey(key) || typeof value !== 'string') continue;
        scanned += 1;
        for (const word of words) {
          if (value.toLowerCase().includes(word)) problems.push(`${locale} common.${key}: ${value}`);
        }
      }
    }
    // Scanning nothing means the key prefixes or the path broke; without this the test would pass forever.
    expect(scanned).toBeGreaterThanOrEqual(Object.keys(FORBIDDEN).length * 40);
    expect(problems).toEqual([]);
  });
});
