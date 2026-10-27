import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { createTranslator } from 'use-intl/core';

// Batch delete confirmation copy: sidebar.batchDeleteConfirm uses ICU plurals and the cancel button uses common.cancel.
// The global setup mocks next-intl to echo keys, so here the use-intl core formats the real messages directly.
const MESSAGES_DIR = path.join(process.cwd(), 'messages');

function readMessages(locale: string): Record<string, unknown> {
  return JSON.parse(readFileSync(path.join(MESSAGES_DIR, `${locale}.json`), 'utf8'));
}

function translator(locale: string, namespace: string) {
  return createTranslator({ locale, messages: readMessages(locale), namespace } as never) as unknown as (
    key: string,
    values?: Record<string, number>,
  ) => string;
}

const LOCALES = readdirSync(MESSAGES_DIR)
  .filter((f) => f.endsWith('.json'))
  .map((f) => f.replace(/\.json$/, ''));

describe('batch delete confirm copy', () => {
  it('en: count=1 uses the singular, count=2 the plural', () => {
    const t = translator('en', 'sidebar');
    expect(t('batchDeleteConfirm', { count: 1 })).toBe('Delete 1 conversation?');
    expect(t('batchDeleteConfirm', { count: 2 })).toBe('Delete 2 conversations?');
  });

  it('en: the cancel button copy is the generic Cancel, not the edit mode Done', () => {
    expect(translator('en', 'common')('cancel')).toBe('Cancel');
  });

  it('all 16 locales format with their own plural rules and leave no ICU syntax behind', () => {
    expect(LOCALES).toHaveLength(16);
    for (const locale of LOCALES) {
      const t = translator(locale, 'sidebar');
      for (const count of [0, 1, 2, 3, 5, 11, 21, 100]) {
        const text = t('batchDeleteConfirm', { count });
        expect(text, `${locale} count=${count}`).not.toMatch(/[{}#]|plural/);
        expect(text.length, `${locale} count=${count}`).toBeGreaterThan(0);
      }
    }
  });

  it('ru: one / few / many word forms', () => {
    const t = translator('ru', 'sidebar');
    expect(t('batchDeleteConfirm', { count: 1 })).toBe('Удалить 1 разговор?');
    expect(t('batchDeleteConfirm', { count: 3 })).toBe('Удалить 3 разговора?');
    expect(t('batchDeleteConfirm', { count: 5 })).toBe('Удалить 5 разговоров?');
  });
});
