import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

// aria-labels of the API key reveal toggle: ProviderSetup reads providerSetup, RelaySimpleForm reads providerDetail.
const NAMESPACES = ['providerSetup', 'providerDetail'] as const;
const KEYS = ['showKey', 'hideKey'] as const;

// "Key" must mean the credential. Thai กุญแจ is a door key and Vietnamese phím is a keyboard key;
// a screen reader user hearing "show door key" cannot tell that the button reveals the API key.
const WRONG_SENSE: Record<string, RegExp> = {
  th: /กุญแจ/,
  vi: /phím/i,
};

type Messages = { pages?: Record<string, Record<string, unknown> | undefined> };

function loadLocales(): Array<{ locale: string; messages: Messages }> {
  const messagesDir = join(process.cwd(), 'messages');
  return readdirSync(messagesDir)
    .filter((name) => name.endsWith('.json'))
    .sort()
    .map((fileName) => ({
      locale: fileName.replace(/\.json$/, ''),
      messages: JSON.parse(readFileSync(join(messagesDir, fileName), 'utf8')) as Messages,
    }));
}

function label(messages: Messages, namespace: string, key: string): string {
  const value = messages.pages?.[namespace]?.[key];
  return typeof value === 'string' ? value.trim() : '';
}

describe('API key visibility toggle aria-labels', () => {
  it('exist in every locale, differ by state, and are translated', () => {
    const locales = loadLocales();
    expect(locales).toHaveLength(16);
    const english = locales.find((entry) => entry.locale === 'en')?.messages ?? {};

    const problems = locales.flatMap(({ locale, messages }) =>
      NAMESPACES.flatMap((namespace) => {
        const show = label(messages, namespace, 'showKey');
        const hide = label(messages, namespace, 'hideKey');
        const issues: string[] = [];
        if (!show || !hide) issues.push(`${locale} ${namespace}: missing showKey/hideKey`);
        if (show && show === hide) issues.push(`${locale} ${namespace}: show and hide read the same`);
        if (locale !== 'en') {
          for (const key of KEYS) {
            if (label(messages, namespace, key) === label(english, namespace, key)) {
              issues.push(`${locale} ${namespace}.${key}: still English`);
            }
          }
        }
        return issues;
      }),
    );

    expect(problems).toEqual([]);
  });

  it('refer to the credential, not a door key or a keyboard key', () => {
    const problems = loadLocales().flatMap(({ locale, messages }) => {
      const wrong = WRONG_SENSE[locale];
      if (!wrong) return [];
      return NAMESPACES.flatMap((namespace) =>
        KEYS.map((key) => ({ at: `${locale} ${namespace}.${key}`, value: label(messages, namespace, key) }))
          .filter(({ value }) => wrong.test(value))
          .map(({ at, value }) => `${at} = ${value}`),
      );
    });

    expect(problems).toEqual([]);
  });
});

// The backup password fields (BackupPasswordInput) read common.showCharacters / hideCharacters: the field holds a
// password, not a key, so it cannot reuse showKey above; the wording matches the iOS / Android secure fields.
describe('password visibility toggle aria-labels', () => {
  it('exist in every locale, differ by state, and are translated', () => {
    const locales = loadLocales();
    expect(locales).toHaveLength(16);
    const common = (messages: Messages): Record<string, unknown> =>
      ((messages as { common?: Record<string, unknown> }).common ?? {});
    const english = common(locales.find((entry) => entry.locale === 'en')?.messages ?? {});

    const problems = locales.flatMap(({ locale, messages }) => {
      const show = String(common(messages).showCharacters ?? '').trim();
      const hide = String(common(messages).hideCharacters ?? '').trim();
      const issues: string[] = [];
      if (!show || !hide) issues.push(`${locale}: missing showCharacters/hideCharacters`);
      if (show && show === hide) issues.push(`${locale}: show and hide read the same`);
      if (locale !== 'en' && (show === english.showCharacters || hide === english.hideCharacters)) {
        issues.push(`${locale}: still English`);
      }
      return issues;
    });

    expect(problems).toEqual([]);
  });
});
