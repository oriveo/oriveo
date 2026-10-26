import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

// Disabled reasons, first-attach hints, not-sent markers and one-tap resend for input capabilities (vision / file reading / video): the 22 keys under capability.input, complete in all 16 languages.
// Asserts: every language has all the keys and none is empty; values in non-zh languages must not copy zh-Hans (guards against untranslated backfill).
const MESSAGES_DIR = join(__dirname, '../../../../messages');
const MODALITIES = ['image', 'file', 'video'] as const;
const GROUPS = [
  'hintFirstAttach',
  'disabled.modelAbsent',
  'disabled.wireNotImplemented',
  'disabled.killSwitch',
  'disabled.rejectedRecently',
  'disabled.userRemoved',
  'resendWithout',
] as const;
const KEYS = [
  ...GROUPS.flatMap((group) => MODALITIES.map((modality) => `capability.input.${group}.${modality}`)),
  'capability.input.bubbleNotSentToModel',
];

function lookup(messages: unknown, key: string): unknown {
  return key.split('.').reduce<unknown>(
    (node, part) => (node && typeof node === 'object' ? (node as Record<string, unknown>)[part] : undefined),
    messages,
  );
}

function load(file: string): unknown {
  return JSON.parse(readFileSync(join(MESSAGES_DIR, file), 'utf8'));
}

describe('capability.input messages', () => {
  const locales = readdirSync(MESSAGES_DIR).filter((name) => name.endsWith('.json'));
  const zhHans = load('zh-Hans.json');

  it('covers 16 locales and 22 keys', () => {
    expect(locales).toHaveLength(16);
    expect(KEYS).toHaveLength(22);
  });

  it.each(locales)('%s has every capability.input key with a non-empty value', (file) => {
    const messages = load(file);
    const missing = KEYS.filter((key) => {
      const value = lookup(messages, key);
      return typeof value !== 'string' || value.trim() === '';
    });
    expect(missing).toEqual([]);
  });

  it.each(locales.filter((file) => !file.startsWith('zh-')))('%s does not copy zh-Hans values', (file) => {
    const messages = load(file);
    const copied = KEYS.filter((key) => lookup(messages, key) === lookup(zhHans, key));
    expect(copied).toEqual([]);
  });
});
