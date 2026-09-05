import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

const REQUIRED_PROVIDER_DETAIL_KEYS = [
  'addedModels',
  'addedModelsHint',
  'noAddedModels',
  'addAll',
  'removeAll',
] as const;

describe('providerDetail message coverage', () => {
  it('includes added-model copy in every locale', () => {
    const messagesDir = join(process.cwd(), 'messages');
    const localeFiles = readdirSync(messagesDir)
      .filter((name) => name.endsWith('.json'))
      .sort();

    const missingByLocale = localeFiles.map((fileName) => {
      const filePath = join(messagesDir, fileName);
      const messages = JSON.parse(readFileSync(filePath, 'utf8')) as {
        pages?: { providerDetail?: Record<string, string> };
      };
      const providerDetail = messages.pages?.providerDetail ?? {};
      const missingKeys = REQUIRED_PROVIDER_DETAIL_KEYS.filter((key) => !(key in providerDetail));

      return {
        locale: fileName.replace(/\.json$/, ''),
        missingKeys,
      };
    }).filter((entry) => entry.missingKeys.length > 0);

    expect(missingByLocale).toEqual([]);
  });

  it('keeps added-model ICU copy structurally valid in every locale', () => {
    const messagesDir = join(process.cwd(), 'messages');
    const localeFiles = readdirSync(messagesDir)
      .filter((name) => name.endsWith('.json'))
      .sort();

    const invalidLocales = localeFiles.map((fileName) => {
      const filePath = join(messagesDir, fileName);
      const messages = JSON.parse(readFileSync(filePath, 'utf8')) as {
        pages?: { providerDetail?: Record<string, string> };
      };
      const providerDetail = messages.pages?.providerDetail ?? {};
      const hint = providerDetail.addedModelsHint ?? '';
      const hasPluralCount = hint.includes('{count, plural');
      const hasCountPlaceholder = hint.includes('#') || hint.includes('{count}');

      return {
        locale: fileName.replace(/\.json$/, ''),
        hasPluralCount,
        hasCountPlaceholder,
      };
    }).filter((entry) => !entry.hasPluralCount || !entry.hasCountPlaceholder);

    expect(invalidLocales).toEqual([]);
  });
});
